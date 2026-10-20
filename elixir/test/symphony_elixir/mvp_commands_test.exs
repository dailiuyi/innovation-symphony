defmodule SymphonyElixir.Mvp.CommandsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Commands, Receipt}

  test "missing timeout fails closed for commands and Git without launching a process" do
    original = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent-symphony-test-path")
      assert {:error, :mvp_requires_gnu_timeout} = Commands.run(["git", "status"], System.tmp_dir!(), 1_000)
      assert {:error, :mvp_requires_gnu_timeout} = Commands.git(["status"], System.tmp_dir!())

      assert_raise RuntimeError, ~r/mvp_requires_gnu_timeout/, fn ->
        Commands.git!(["status"], System.tmp_dir!())
      end
    after
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end
  end

  describe "scoped Git fetch deadline" do
    setup do
      root = Path.join(System.tmp_dir!(), "symphony-fetch-deadline-#{System.unique_integer([:positive])}")
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      original = Map.new(["PATH", "TMPDIR"], &{&1, System.get_env(&1)})
      assert {version, 0} = System.cmd("/usr/bin/timeout", ["--version"])
      assert version =~ "GNU coreutils"

      File.write!(Path.join(bin, "timeout"), """
      #!/bin/sh
      printf '%s\\n' "$@" > "$COMMANDS_TIMEOUT_ARGV"
      exec /usr/bin/timeout "$@"
      """)

      File.write!(Path.join(bin, "git"), """
      #!/bin/sh
      printf '%s\\n' "$@" > "$COMMANDS_GIT_ARGV"
      if [ -n "${COMMANDS_GIT_SLEEP:-}" ]; then exec /bin/sleep "$COMMANDS_GIT_SLEEP"; fi
      printf '  fixture output \\n'
      exit "${COMMANDS_GIT_STATUS:-0}"
      """)

      File.chmod!(Path.join(bin, "timeout"), 0o755)
      File.chmod!(Path.join(bin, "git"), 0o755)
      System.put_env("PATH", bin)
      System.put_env("TMPDIR", root)

      on_exit(fn ->
        Enum.each(original, fn {key, value} -> restore_env(key, value) end)
        File.rm_rf!(root)
      end)

      opts = [env: [{"COMMANDS_TIMEOUT_ARGV", Path.join(root, "timeout.argv")}, {"COMMANDS_GIT_ARGV", Path.join(root, "git.argv")}]]
      {:ok, root: root, command_opts: opts}
    end

    test "only a first-argument fetch within the scope changes the existing 120 second timeout", context do
      assert {:ok, "fixture output"} = Commands.git(["fetch", "origin"], context.root, context.command_opts)
      assert timeout_argv(context.root) |> Enum.take(3) == ["--kill-after=5s", "120s", "git"]

      Commands.with_git_fetch_deadline(0, fn ->
        for args <- [["status"], ["push", "origin"], ["-C", context.root, "fetch"], ["FETCH"], []] do
          assert {:ok, "fixture output"} = Commands.git(args, context.root, context.command_opts)
          assert Enum.at(timeout_argv(context.root), 1) == "120s"
        end

        assert {:ok, "  fixture output \n"} = Commands.run(["git", "fetch"], context.root, 120_000, context.command_opts)
        assert Enum.at(timeout_argv(context.root), 1) == "120s"
        assert {:ok, "  fixture output \n"} = Commands.run(["git", "fetch"], context.root, 1, context.command_opts)
        assert Enum.at(timeout_argv(context.root), 1) == "1s"
      end)

      assert {:ok, "fixture output"} = Commands.git(["fetch"], context.root, context.command_opts)
      assert Enum.at(timeout_argv(context.root), 1) == "120s"
    end

    test "GNU timeout receives at most the remaining wall budget including subsecond budgets", context do
      for budget <- [345_678, 999] do
        deadline = System.system_time(:millisecond) + budget

        Commands.with_git_fetch_deadline(deadline, fn ->
          before = System.system_time(:millisecond)
          assert {:ok, "fixture output"} = Commands.git(["fetch", "origin"], context.root, context.command_opts)
          after_ms = System.system_time(:millisecond)
          duration_ms = timeout_ms(context.root)
          assert duration_ms > 0
          assert duration_ms <= deadline - before
          assert duration_ms >= deadline - after_ms
          assert duration_ms <= 1_800_000
          assert hd(timeout_argv(context.root)) == "--kill-after=5s"
        end)
      end
    end

    test "long fetch budgets are capped at thirty minutes and preserve Git options and failures", context do
      Commands.with_git_fetch_deadline(System.system_time(:millisecond) + 7_200_000, fn ->
        assert {:ok, "  fixture output \n"} =
                 Commands.git(["fetch", "origin", "main"], context.root, Keyword.put(context.command_opts, :preserve_output, true))

        assert timeout_argv(context.root) == [
                 "--kill-after=5s",
                 "1800s",
                 "git",
                 "-c",
                 "core.hooksPath=#{Path.join(context.root, "innovation-symphony-empty-hooks")}",
                 "-c",
                 "credential.helper=",
                 "-c",
                 "user.name=Symphony",
                 "-c",
                 "user.email=symphony@localhost",
                 "fetch",
                 "origin",
                 "main"
               ]

        failed = Keyword.update!(context.command_opts, :env, &[{"COMMANDS_GIT_STATUS", "23"} | &1])
        assert {:error, {:git_failed, "fetch", 23}} = Commands.git(["fetch"], context.root, failed)
      end)
    end

    test "expired fetches cause neither filesystem changes nor process launches", context do
      before = File.ls!(context.root) |> Enum.sort()

      Commands.with_git_fetch_deadline(System.system_time(:millisecond) - 1, fn ->
        assert {:error, :mvp_recovery_resource_exhausted} =
                 Commands.git(["fetch", "origin"], Path.join(context.root, "missing-cwd"), context.command_opts)

        assert_raise RuntimeError, ~r/mvp_recovery_resource_exhausted/, fn ->
          Commands.git!(["fetch"], context.root, context.command_opts)
        end
      end)

      assert File.ls!(context.root) |> Enum.sort() == before
      refute File.exists?(Path.join(context.root, "timeout.argv"))
      refute File.exists?(Path.join(context.root, "git.argv"))
      refute File.exists?(Path.join(context.root, "innovation-symphony-empty-hooks"))
    end

    test "nested scopes return callback results and restore the outer and default deadlines", context do
      assert :outer_result =
               Commands.with_git_fetch_deadline(System.system_time(:millisecond) + 7_200_000, fn ->
                 assert :inner_result =
                          Commands.with_git_fetch_deadline(0, fn ->
                            assert {:error, :mvp_recovery_resource_exhausted} = Commands.git(["fetch"], context.root, context.command_opts)
                            :inner_result
                          end)

                 assert {:ok, "fixture output"} = Commands.git(["fetch"], context.root, context.command_opts)
                 assert timeout_ms(context.root) == 1_800_000
                 :outer_result
               end)

      assert {:ok, "fixture output"} = Commands.git(["fetch"], context.root, context.command_opts)
      assert timeout_ms(context.root) == 120_000
    end

    test "raises throws and exits restore the previous scope and propagate unchanged", context do
      Commands.with_git_fetch_deadline(0, fn ->
        assert_raise RuntimeError, "deadline fixture", fn ->
          Commands.with_git_fetch_deadline(System.system_time(:millisecond) + 7_200_000, fn -> raise "deadline fixture" end)
        end

        assert {:error, :mvp_recovery_resource_exhausted} = Commands.git(["fetch"], context.root, context.command_opts)
      end)

      assert catch_throw(Commands.with_git_fetch_deadline(0, fn -> throw(:fixture_throw) end)) == :fixture_throw
      assert catch_exit(Commands.with_git_fetch_deadline(0, fn -> exit(:fixture_exit) end)) == :fixture_exit
      assert {:ok, "fixture output"} = Commands.git(["fetch"], context.root, context.command_opts)
      assert timeout_ms(context.root) == 120_000
    end

    test "the deadline is process-local and does not leak to a child process", context do
      Commands.with_git_fetch_deadline(0, fn ->
        task = Task.async(fn -> Commands.git(["fetch"], context.root, context.command_opts) end)
        assert {:ok, "fixture output"} = Task.await(task)
        assert timeout_ms(context.root) == 120_000
        assert {:error, :mvp_recovery_resource_exhausted} = Commands.git(["fetch"], context.root, context.command_opts)
      end)
    end

    test "a scoped fetch still fails closed without GNU timeout", context do
      System.put_env("PATH", "/nonexistent-symphony-test-path")

      Commands.with_git_fetch_deadline(System.system_time(:millisecond) + 60_000, fn ->
        assert {:error, :mvp_requires_gnu_timeout} = Commands.git(["fetch"], context.root, context.command_opts)
      end)

      refute File.exists?(Path.join(context.root, "timeout.argv"))
      refute File.exists?(Path.join(context.root, "git.argv"))
    end

    test "GNU timeout actually terminates a fetch and the same scope then refuses another spawn", context do
      opts = Keyword.update!(context.command_opts, :env, &[{"COMMANDS_GIT_SLEEP", "5"} | &1])

      Commands.with_git_fetch_deadline(System.system_time(:millisecond) + 200, fn ->
        assert {:error, {:git_failed, "fetch", 124}} = Commands.git(["fetch"], context.root, opts)
        assert timeout_ms(context.root) <= 200
        argv = File.read!(Path.join(context.root, "timeout.argv"))
        git_argv = File.read!(Path.join(context.root, "git.argv"))
        assert {:error, :mvp_recovery_resource_exhausted} = Commands.git(["fetch", "again"], context.root, opts)
        assert File.read!(Path.join(context.root, "timeout.argv")) == argv
        assert File.read!(Path.join(context.root, "git.argv")) == git_argv
      end)
    end
  end

  @tag :unix
  test "a receipt path beyond filesystem limits reports admission failure" do
    root = Path.join(System.tmp_dir!(), "symphony-receipt-limit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    # Each component is valid; the receipt filename alone takes the full path beyond Linux PATH_MAX.
    state_dir = Enum.reduce(1..16, root, fn _, path -> Path.join(path, String.duplicate("a", 250)) end)
    issue = %{id: "1", native_ref: %{"repo" => "owner/repo"}}

    assert {:error, {:mvp_receipt_write, :enametoolong}} = Receipt.claim(%{state_dir: state_dir}, issue)
    assert File.dir?(state_dir)
  end

  defp timeout_argv(root), do: root |> Path.join("timeout.argv") |> File.read!() |> String.split("\n", trim: true)

  defp timeout_ms(root) do
    {seconds, "s"} = root |> timeout_argv() |> Enum.at(1) |> Float.parse()
    round(seconds * 1_000)
  end
end
