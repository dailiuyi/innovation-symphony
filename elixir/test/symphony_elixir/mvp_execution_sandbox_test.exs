defmodule SymphonyElixir.MvpExecutionSandboxTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.ExecutionSandbox

  test "host hashing is chunked and rejects oversized source or aggregate export before import" do
    context = context!()
    context = put_in(context.settings.sandbox["disk_mb"], 1)
    oversized = Path.join(context.workspace, "large.bin")
    File.write!(oversized, :binary.copy(<<0>>, 1_048_577))
    rejected = with_agent(context, fn _, _, _, _ -> flunk("oversized source must not start an agent") end)
    assert {:error, :sandbox_source_size_limit} = ExecutionSandbox.agent(rejected, :coder, "task", [])
    File.rm!(oversized)

    agent = fn _, _, _, options ->
      scratch = scratch(options)
      export!(scratch, %{"a.bin" => :binary.copy(<<0>>, 600_000), "b.bin" => :binary.copy(<<0>>, 600_000)})
      result!(scratch)
      {:ok, %{output_text: "done"}}
    end

    assert {:error, :sandbox_source_size_limit} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "task", [])
    assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    refute File.exists?(Path.join(context.workspace, "a.bin"))
  end

  test "configuration requires explicit isolated paths and bounded resources" do
    context = context!()
    config = context.settings.sandbox |> Map.delete(:enabled) |> Map.put("enabled", true) |> Map.drop(~w(memory_mb disk_mb pids cpus))
    assert {:ok, %{enabled: false}} = ExecutionSandbox.settings(nil)
    assert {:ok, %{enabled: false}} = ExecutionSandbox.settings(%{"enabled" => false})
    refute ExecutionSandbox.enabled?(%{})
    refute ExecutionSandbox.enabled?(%{sandbox: %{enabled: false}})
    assert ExecutionSandbox.enabled?(context.settings)
    assert {:ok, defaults} = ExecutionSandbox.settings(config)
    assert defaults["memory_mb"] > 0 and defaults["disk_mb"] > 0
    refute Map.has_key?(defaults, "enabled")
    assert Jason.encode!(defaults) |> String.split("\"enabled\"") |> length() == 2

    for {key, minimum, maximum} <- [{"memory_mb", 128, 65_536}, {"disk_mb", 128, 65_536}, {"pids", 1, 65_536}, {"cpus", 1, 64}] do
      assert {:ok, _} = ExecutionSandbox.settings(Map.put(config, key, minimum))
      assert {:ok, _} = ExecutionSandbox.settings(Map.put(config, key, maximum))
      assert {:error, :invalid_execution_sandbox} = ExecutionSandbox.settings(Map.put(config, key, minimum - 1))
      assert {:error, :invalid_execution_sandbox} = ExecutionSandbox.settings(Map.put(config, key, maximum + 1))
    end

    for invalid <- [
          false,
          %{},
          %{"enabled" => false, "root" => "/unused"},
          Map.put(config, "unknown", 1),
          Map.put(config, "root", "relative"),
          Map.put(config, "root", "/tmp/unsafe\npath"),
          Map.delete(config, "auth_home"),
          Map.put(config, "pids", 0),
          Map.put(config, "cpus", 65_537),
          Map.put(config, "memory_mb", "4096")
        ] do
      assert {:error, :invalid_execution_sandbox} = ExecutionSandbox.settings(invalid)
    end

    disabled = %{config: %{"mvp" => %{"enabled" => false}}}
    assert {:ok, %{sandbox: %{enabled: false}}} = MvpConfig.settings(disabled, "/unused")

    assert {:error, :invalid_execution_sandbox} =
             MvpConfig.settings(%{config: %{"mvp" => %{"enabled" => false, "sandbox" => %{}}}}, "/unused")
  end

  test "coder receives an isolated executor and only completed source changes are imported" do
    context = context!()
    File.write!(Path.join(context.workspace, "remove.txt"), "remove")
    File.mkdir_p!(Path.join(context.workspace, "elixir/_build"))
    File.write!(Path.join(context.workspace, "elixir/_build/host-cache"), "host")
    File.mkdir_p!(Path.join(context.workspace, ".codex"))
    File.write!(Path.join(context.workspace, ".codex/host-config"), "host")

    agent = fn workspace, prompt, issue, options ->
      assert workspace == context.workspace and issue == context.issue
      assert prompt =~ "THIS session"
      assert prompt =~ "/workspace/source.txt"
      assert prompt =~ "/evidence/check.log"
      refute prompt =~ context.workspace
      refute prompt =~ context.evidence
      assert options[:model] == "frozen-model"
      environment = options[:execution_environment]
      assert environment.id == "task" and environment.cwd == "/workspace"
      refute String.starts_with?(environment.codex_home, context.workspace <> "/")
      assert File.read!(Path.join(environment.codex_home, "environments.toml")) =~ "include_local = false"
      assert File.read!(Path.join(environment.codex_home, "config.toml")) =~ "web_search = \"disabled\""
      assert File.read!(Path.join(environment.codex_home, "auth.json")) == "fake-model-auth"
      scratch = scratch(options)
      export!(scratch, %{"source.txt" => "fixed", "new/added.txt" => "added", "elixir/_build/host-cache" => "untrusted", ".codex/host-config" => "untrusted"})
      result!(scratch)
      {:ok, %{output_text: "tests passed"}}
    end

    prompt = "Implement #{context.workspace}/source.txt using #{context.evidence}/check.log"
    assert {:ok, %{output_text: "tests passed"}} = ExecutionSandbox.agent(with_agent(context, agent), :coder, prompt, model: "frozen-model", wall_timeout_ms: 900)
    assert File.read!(Path.join(context.workspace, "source.txt")) == "fixed"
    assert File.read!(Path.join(context.workspace, "new/added.txt")) == "added"
    refute File.exists?(Path.join(context.workspace, "remove.txt"))
    assert File.read!(Path.join(context.workspace, "elixir/_build/host-cache")) == "host"
    assert File.read!(Path.join(context.workspace, ".codex/host-config")) == "host"
  end

  test "review and diagnosis do not import their disposable changes" do
    for role <- [:reviewer, :diagnosis] do
      context = context!()

      agent = fn _, prompt, _, options ->
        assert prompt =~ "frozen base is /baseline"
        export!(scratch(options), %{"source.txt" => "untrusted rewrite"})
        result!(scratch(options))
        {:ok, %{output_text: "read-only result"}}
      end

      assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), role, "Inspect", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    end
  end

  test "model failure is retained after safe cleanup without pretending it passed" do
    context = context!()

    agent = fn _, _, _, options ->
      export!(scratch(options), %{"source.txt" => "partial repair"})
      result!(scratch(options))
      {:error, :turn_timeout}
    end

    assert {:error, :turn_timeout} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
  end

  test "missing authorization material and overlapping roots fail before invoking an agent" do
    context = context!()
    context = with_agent(context, fn _, _, _, _ -> flunk("must not start") end)
    File.rm!(Path.join(context.settings.sandbox["auth_home"], "auth.json"))
    assert {:error, :sandbox_auth_unavailable} = ExecutionSandbox.agent(context, :coder, "Repair", [])

    for root <- [context.workspace, Path.join(context.workspace, "nested"), Path.dirname(context.workspace)] do
      overlap = put_in(context, [:settings, :sandbox, "root"], root)
      assert {:error, :sandbox_root_overlaps_workspace} = ExecutionSandbox.agent(overlap, :coder, "Repair", [])
    end
  end

  test "raised model errors still wait for descendant cleanup and retain safe partial work" do
    context = context!()

    agent = fn _, _, _, options ->
      scratch = scratch(options)
      export!(scratch, %{"source.txt" => "partial repair"})
      parent = self()

      spawn(fn ->
        Process.sleep(10)
        result!(scratch)
        send(parent, :cleanup_completed)
      end)

      raise "model transport crashed"
    end

    context = context |> with_agent(agent) |> put_in([:opts, :sandbox_cleanup_timeout_ms], 200)
    assert {:error, {:sandbox_invocation_failed, :error, %RuntimeError{}}} = ExecutionSandbox.agent(context, :coder, "Repair", [])
    assert_received :cleanup_completed
    assert File.read!(Path.join(context.workspace, "source.txt")) == "partial repair"
  end

  test "model success cannot conceal an executor timeout" do
    context = context!()

    agent = fn _, _, _, options ->
      export!(scratch(options), %{"source.txt" => "partial repair"})
      result!(scratch(options), 124)
      {:ok, %{output_text: "passed"}}
    end

    assert {:error, {:sandbox_process_failed, 124}} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
  end

  test "symlink sandbox roots cannot disguise a workspace overlap" do
    context = context!()
    link = Path.join(context.root, "root-link")
    File.ln_s!(context.workspace, link)
    context = context |> put_in([:settings, :sandbox, "root"], link) |> with_agent(fn _, _, _, _ -> flunk("must not start") end)
    assert {:error, _} = ExecutionSandbox.agent(context, :coder, "Repair", [])
  end

  test "source links are rejected before invoking the model" do
    context = context!()
    File.ln_s!(Path.join(context.root, "sensitive"), Path.join(context.workspace, "escape"))
    context = with_agent(context, fn _, _, _, _ -> flunk("must not start") end)
    assert {:error, {:sandbox_unsupported_file, "escape"}} = ExecutionSandbox.agent(context, :coder, "Repair", [])
  end

  test "trusted mounts and credentials cannot alias candidate or mounted trees" do
    context = context!() |> with_agent(fn _, _, _, _ -> flunk("must not start") end)
    alias_path = Path.join(context.root, "alias")
    File.ln_s!(context.outside, alias_path)

    for key <- ~w(toolchain codex dependencies trusted_root auth_home),
        path <- [context.workspace, Path.join(context.workspace, "nested"), alias_path] do
      unsafe = put_in(context, [:settings, :sandbox, key], path)
      assert {:error, _} = ExecutionSandbox.agent(unsafe, :coder, "Repair", [])
    end

    mounts = [context.workspace, context.evidence, Path.join(context.evidence, "baseline")]
    mounts = mounts ++ Enum.map(~w(toolchain dependencies trusted_root), &context.settings.sandbox[&1])

    for path <- mounts do
      unsafe = put_in(context, [:settings, :sandbox, "auth_home"], Path.join(path, "credentials"))
      assert {:error, _} = ExecutionSandbox.agent(unsafe, :coder, "Repair", [])
    end

    auth = Path.join(context.settings.sandbox["auth_home"], "auth.json")
    File.rm!(auth)
    File.ln_s!(Path.join(context.workspace, "secret.json"), auth)
    assert {:error, _} = ExecutionSandbox.agent(context, :coder, "Repair", [])
    File.rm!(auth)
    File.ln_s!(Path.join(context.outside, "source.txt/not-a-directory"), auth)
    assert {:error, _} = ExecutionSandbox.agent(context, :coder, "Repair", [])
  end

  test "import IO failures restore originals and retain a recovery journal" do
    for failure <- [:copy, :backup, :install, :exception] do
      context = context!()
      File.write!(Path.join(context.workspace, "deleted.txt"), "retain deleted original")

      agent = fn _, _, _, options ->
        export!(scratch(options), %{"source.txt" => "replacement", "added.txt" => "new"})
        result!(scratch(options))
        {:ok, %{}}
      end

      operation = fn action, source, target ->
        fail =
          case failure do
            :copy -> action == :copy and Path.basename(source) == "source.txt"
            :backup -> String.contains?(target, "/backup/source.txt")
            _ -> String.contains?(source, "/new/source.txt")
          end

        cond do
          fail and failure == :exception -> raise "interrupted import"
          fail -> {:error, :enospc}
          action == :copy -> File.cp(source, target)
          true -> File.rename(source, target)
        end
      end

      context = with_agent(context, agent)
      context = update_in(context.opts, &Keyword.put(&1, :sandbox_import_file, operation))
      assert {:error, {:sandbox_import_failed, transaction, _, :ok}} = ExecutionSandbox.agent(context, :coder, "Repair", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
      assert File.read!(Path.join(context.workspace, "deleted.txt")) == "retain deleted original"
      refute File.exists?(Path.join(context.workspace, "added.txt"))
      assert File.regular?(Path.join(transaction, "journal.json"))
      context = with_agent(context, fn _, _, _, _ -> flunk("unresolved import must block") end)
      assert {:error, _} = ExecutionSandbox.agent(context, :coder, "Repair", [])
    end
  end

  test "export links and an export-root symlink are rejected before host writes" do
    for root_link <- [false, true] do
      context = context!()

      agent = fn _, _, _, options ->
        scratch = scratch(options)
        File.mkdir_p!(scratch)

        if root_link do
          File.ln_s!(context.outside, Path.join(scratch, "export"))
        else
          export!(scratch, %{"source.txt" => "must not copy"})
          File.ln_s!(context.outside, Path.join(scratch, "export/escape"))
        end

        result!(scratch)
        {:ok, %{}}
      end

      assert {:error, _} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    end
  end

  test "a concurrently changed destination is not overwritten" do
    context = context!()

    agent = fn _, _, _, options ->
      export!(scratch(options), %{"source.txt" => "model rewrite"})
      result!(scratch(options))
      File.write!(Path.join(context.workspace, "source.txt"), "another actor")
      {:ok, %{}}
    end

    assert {:error, :sandbox_workspace_changed} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
    assert File.read!(Path.join(context.workspace, "source.txt")) == "another actor"
  end

  test "file and directory conflicts reject the complete import before deleting source" do
    for target <- ["replace_dir", "source.txt/nested", "replace_dir/old/nested"] do
      context = context!()
      File.mkdir_p!(Path.join(context.workspace, "replace_dir"))
      File.write!(Path.join(context.workspace, "replace_dir/old"), "keep old file")

      agent = fn _, _, _, options ->
        export!(scratch(options), %{target => "replacement", "unrelated.txt" => "must not copy"})
        result!(scratch(options))
        {:ok, %{}}
      end

      assert {:error, {:sandbox_import_path_conflict, ^target}} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
      assert File.read!(Path.join(context.workspace, "replace_dir/old")) == "keep old file"
      refute File.exists?(Path.join(context.workspace, "unrelated.txt"))
    end
  end

  test "cleanup and export evidence are required even if the model claims success" do
    for result <- [
          :missing,
          :malformed,
          :directory,
          :symlink,
          :stale,
          :invalid_status,
          %{},
          %{"cleanup_complete" => false, "export_complete" => true},
          %{"cleanup_complete" => true, "export_complete" => false}
        ] do
      context = context!()

      agent = fn _, _, _, options ->
        scratch = scratch(options)
        export!(scratch, %{"source.txt" => "must not import"})

        case result do
          :missing ->
            :ok

          :malformed ->
            File.write!(Path.join(scratch, "result.json"), "broken")

          :directory ->
            File.mkdir!(Path.join(scratch, "result.json"))

          :symlink ->
            result!(context.outside)
            File.ln_s!(Path.join(context.outside, "result.json"), Path.join(scratch, "result.json"))

          :stale ->
            result!(context.outside)
            File.cp!(Path.join(context.outside, "result.json"), Path.join(scratch, "result.json"))

          :invalid_status ->
            result!(scratch, "0")

          value ->
            File.write!(Path.join(scratch, "result.json"), Jason.encode!(value))
        end

        {:ok, %{output_text: "passed"}}
      end

      assert {:error, _} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    end
  end

  test "a completed cleanup without an export directory cannot remove host source" do
    context = context!()

    agent = fn _, _, _, options ->
      result!(scratch(options))
      {:ok, %{}}
    end

    assert {:error, _} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
    assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
  end

  test "formal candidate and baseline checks use the isolated runner and preserve evidence" do
    for kind <- ["candidate", "baseline"] do
      context = git_context!()
      log = Path.join(context.root, "#{kind}.log")

      command = fn argv, cwd, timeout, output ->
        assert cwd == context.workspace and output == log
        assert timeout > 100
        assert "/opt/symphony/scripts/check_isolated.py" in argv
        assert kind in argv
        assert "--candidate-sha" in argv
        assert argv_value(argv, "--evidence") == context.evidence
        scratch = argv_value(argv, "--scratch-root")
        export!(scratch, %{".check-evidence/report.json" => "complete report"})
        result!(scratch, 10)
        File.write!(output, "full check output")
        {:ok, 10}
      end

      context = put_in(context.opts, sandbox_command_run: command, sandbox_cleanup_timeout_ms: 1)
      assert {:ok, 10} = ExecutionSandbox.check(context, ["python3", "/trusted/check_#{kind}.py", context.workspace], 100, log)
      assert File.read!(Path.rootname(log) <> "-details/report.json") == "complete report"
      assert File.read!(log) == "full check output"
    end
  end

  test "unsupported checks never fall back to a host command" do
    context = context!()
    context = put_in(context.opts, sandbox_command_run: fn _, _, _, _ -> flunk("must not run") end)

    for command <- [["mix", "test"], ["python3", "/trusted/other.py"]] do
      assert {:error, :unsupported_isolated_check} = ExecutionSandbox.check(context, command, 100, Path.join(context.root, "check.log"))
    end
  end

  test "formal checks retain invocation errors and reject inconsistent exit evidence" do
    for returned <- [{:ok, 0}, {:error, :transport_failed}, :raise] do
      context = git_context!()

      command = fn argv, _, _, _ ->
        scratch = argv_value(argv, "--scratch-root")
        export!(scratch, %{".check-evidence/report.json" => "failed check"})
        result!(scratch, 10)
        if returned == :raise, do: raise("check transport failed"), else: returned
      end

      context = put_in(context.opts, sandbox_command_run: command, sandbox_cleanup_timeout_ms: 1)
      result = ExecutionSandbox.check(context, ["python3", "/trusted/check_candidate.py"], 100, Path.join(context.root, "check.log"))

      case returned do
        {:ok, 0} -> assert result == {:error, :sandbox_check_exit_mismatch}
        {:error, :transport_failed} -> assert result == returned
        :raise -> assert {:error, {:sandbox_invocation_failed, :error, %RuntimeError{}}} = result
      end
    end
  end

  test "formal checks reject absent evidence and symlink evidence roots" do
    for evidence <- [:missing, :symlink, :nested_symlink] do
      context = git_context!()

      command = fn argv, _, _, _ ->
        scratch = argv_value(argv, "--scratch-root")
        export!(scratch, %{})

        case evidence do
          :missing ->
            :ok

          :symlink ->
            File.ln_s!(context.outside, Path.join(scratch, "export/.check-evidence"))

          :nested_symlink ->
            File.mkdir_p!(Path.join(scratch, "export/.check-evidence"))
            File.ln_s!(context.outside, Path.join(scratch, "export/.check-evidence/escape"))
        end

        result!(scratch)
        {:ok, 0}
      end

      context = put_in(context.opts, sandbox_command_run: command, sandbox_cleanup_timeout_ms: 1)
      assert {:error, _} = ExecutionSandbox.check(context, ["python3", "/trusted/check_candidate.py"], 100, Path.join(context.root, "check.log"))
    end
  end

  defp context! do
    root = Path.join(System.tmp_dir!(), "symphony-execution-sandbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    for directory <- [workspace, outside, Path.join(root, "auth"), Path.join(root, "evidence/baseline")], do: File.mkdir_p!(directory)
    File.write!(Path.join(workspace, "source.txt"), "original")
    File.write!(Path.join(outside, "source.txt"), "sensitive")
    File.write!(Path.join(root, "auth/auth.json"), "fake-model-auth")

    config = %{
      "enabled" => true,
      "root" => Path.join(root, "sandboxes"),
      "toolchain" => "/trusted/toolchain",
      "codex" => "/trusted/codex",
      "dependencies" => "/trusted/dependencies",
      "trusted_root" => "/trusted/runtime",
      "auth_home" => Path.join(root, "auth")
    }

    {:ok, sandbox} = ExecutionSandbox.settings(config)

    %{
      root: root,
      outside: outside,
      workspace: workspace,
      evidence: Path.join(root, "evidence"),
      issue: %{id: "test"},
      settings: %{sandbox: sandbox, check_timeout_ms: 100},
      opts: [sandbox_cleanup_timeout_ms: 1]
    }
  end

  defp git_context! do
    context = context!()

    for args <- [["init", "--quiet"], ["add", "source.txt"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture"]] do
      {_, 0} = System.cmd("git", args, cd: context.workspace, stderr_to_stdout: true)
    end

    context
  end

  defp with_agent(context, agent), do: %{context | opts: Keyword.put(context.opts, :sandbox_agent_run, agent)}
  defp scratch(options), do: options[:execution_environment].codex_home |> Path.dirname() |> Path.join("sandbox")
  defp argv_value(argv, flag), do: argv |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp export!(scratch, files) do
    File.mkdir_p!(Path.join(scratch, "export"))

    Enum.each(files, fn {path, contents} ->
      target = Path.join([scratch, "export", path])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, contents)
    end)
  end

  defp result!(scratch, status \\ 0) do
    File.mkdir_p!(scratch)
    File.write!(Path.join(scratch, "result.json"), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true, "scratch_root" => scratch, "exit_status" => status}))
  end
end
