defmodule SymphonyElixir.MvpExecutionSandboxTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ModelServicesFixture, as: ModelFixture
  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.{ExecutionSandbox, ModelCatalog, ModelServices}

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
      assert options[:wall_timeout_ms] == 900
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

  test "model budgets for coder reviewer and diagnosis remain independent of formal check timeout" do
    context = context!()

    for role <- [:coder, :reviewer, :diagnosis] do
      agent = fn _, _, _, options ->
        assert options[:wall_timeout_ms] == 30_000
        config = File.read!(Path.join(options[:execution_environment].codex_home, "environments.toml"))
        assert config =~ ~s("--timeout-seconds","30")
        if role == :coder, do: export!(scratch(options), %{"source.txt" => "original"})
        result!(scratch(options))
        {:ok, %{output_text: "done"}}
      end

      assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), role, "test", wall_timeout_ms: 30_000)
    end

    agent = fn _, _, _, options ->
      assert options[:wall_timeout_ms] == Config.settings!().codex.turn_timeout_ms
      export!(scratch(options), %{"source.txt" => "original"})
      result!(scratch(options))
      {:ok, %{output_text: "done"}}
    end

    assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "test", [])
  end

  test "invalid model wall budgets refuse before preparing an executor" do
    context = context!()

    for timeout <- [nil, false, 0, -1, "30000"] do
      assert {:error, :invalid_wall_timeout} =
               ExecutionSandbox.agent(context, :coder, "test", wall_timeout_ms: timeout)

      refute File.exists?(context.settings.sandbox["root"])
    end
  end

  test "invalid operator agent caps refuse before preparing an executor" do
    context = context!()

    for cap <- [nil, false, 0, -1, "30000"] do
      invalid = Map.update!(context, :opts, &Keyword.put(&1, :agent_timeout_ms, cap))

      assert {:error, :invalid_wall_timeout} =
               ExecutionSandbox.agent(invalid, :coder, "test", wall_timeout_ms: 30_000)

      refute File.exists?(context.settings.sandbox["root"])
    end
  end

  test "isolated homes use role services instead of shared auth and reasoning defaults" do
    context = context!()
    System.put_env("GH12_CODER_KEY", "sandbox-synthetic-coder")
    System.put_env("GH12_REVIEWER_KEY", "sandbox-synthetic-reviewer")

    on_exit(fn ->
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    settings = ModelFixture.settings(context.root)

    for {role, id} <- [{:coder, "coding"}, {:reviewer, "reviewing"}] do
      {:ok, service} = ModelServices.snapshot(settings, id, role, "fixture")

      agent = fn _, _, _, options ->
        home = options[:execution_environment].codex_home
        config = File.read!(Path.join(home, "config.toml"))
        assert config =~ service["connection"]["base_url"]
        assert config =~ service["parameters"]["reasoning_effort"]
        refute File.exists?(Path.join(home, "auth.json"))
        refute config =~ "sandbox-synthetic"
        assert options[:execution_environment].read_only == (role != :coder)
        export!(scratch(options), %{"source.txt" => "source"})
        result!(scratch(options))
        {:ok, %{output_text: "routed"}}
      end

      assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), role, "test", model_service: service)
    end
  end

  test "legacy effort flags survive isolated role calls and diagnosis after configuration changes" do
    context = context!()
    home = context.settings.sandbox["auth_home"]
    auth = Jason.encode!(%{"OPENAI_API_KEY" => "synthetic-legacy-sandbox"})
    File.write!(Path.join(home, "auth.json"), auth)
    command = ~s(codex -c 'model_reasoning_effort="xhigh"' app-server)
    settings = Map.put(context.settings, :model_command, command)
    models = %{coder: "gpt-test", reviewer: "gpt-review"}
    assert {:ok, services} = ModelServices.freeze(models, settings, environment: fn _ -> nil end)
    File.write!(Path.join(home, "config.toml"), ~s(model_reasoning_effort = "low"\n))
    changed = Map.put(settings, :model_command, "codex -c model_reasoning_effort=medium app-server")
    context = %{context | settings: changed}

    for role <- [:coder, :reviewer, :diagnosis] do
      service = services[if(role == :reviewer, do: "reviewer", else: "coder")]

      agent = fn _, _, _, options ->
        environment = options[:execution_environment]
        config = File.read!(Path.join(environment.codex_home, "config.toml"))
        assert options[:model_service] == service
        assert service["command"] == command
        assert service["parameters"] == %{"reasoning_effort" => "xhigh"}
        assert service["credential_ref"] == "auth_home:" <> home
        assert config =~ ~s(model_reasoning_effort = "xhigh")
        assert config =~ ~s(openai_base_url = "https://api.openai.com/v1")
        refute config =~ ~s(model_reasoning_effort = "low")
        assert File.read!(Path.join(environment.codex_home, "auth.json")) == auth
        assert environment.read_only == (role != :coder)
        if role == :coder, do: export!(scratch(options), %{"source.txt" => "original"})
        result!(scratch(options))
        {:ok, %{output_text: "frozen legacy routing"}}
      end

      for _attempt <- 1..2 do
        assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), role, "test", model_service: service)
      end
    end
  end

  test "a selected role auth home is isolated and may not overlap the task" do
    context = context!()
    System.put_env("GH12_CODER_KEY", "synthetic-coder")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-reviewer")

    on_exit(fn ->
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    settings = ModelFixture.settings(context.root)
    home = Path.join(context.root, "role-auth")
    File.mkdir!(home)
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"token" => "synthetic-role-auth"}))
    {:ok, service} = ModelServices.snapshot(settings, "reviewing", :reviewer, "fixture")
    service = Map.put(service, "credential_ref", "auth_home:" <> home)

    agent = fn _, _, _, options ->
      private = options[:execution_environment].codex_home
      assert File.read!(Path.join(private, "auth.json")) == File.read!(Path.join(home, "auth.json"))
      config = File.read!(Path.join(private, "config.toml"))
      assert config =~ ~s(model_provider = "openai")
      assert config =~ service["connection"]["base_url"]
      refute config =~ "[model_providers.openai]"
      result!(scratch(options))
      {:ok, %{output_text: "role account"}}
    end

    assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), :reviewer, "task", model_service: service)
    unsafe = Map.put(service, "credential_ref", "auth_home:" <> context.workspace)
    assert {:error, :sandbox_unsafe_trusted_paths} = ExecutionSandbox.agent(with_agent(context, agent), :reviewer, "task", model_service: unsafe)
  end

  test "a separate operator agent cap respects remaining budget for all roles" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: 300)

    for role <- [:coder, :reviewer, :diagnosis], remaining <- [50, 900] do
      context = context!()

      agent = fn _, _, _, options ->
        assert options[:wall_timeout_ms] == min(remaining, 600)
        environment = options[:execution_environment]
        [_, raw] = Regex.run(~r/^args = (.+)$/m, File.read!(Path.join(environment.codex_home, "environments.toml")))
        assert argv_value(Jason.decode!(raw), "--timeout-seconds") == "1"
        result!(scratch(options))
        if role == :coder, do: export!(scratch(options), %{"source.txt" => "unchanged"})
        {:ok, %{output_text: "done"}}
      end

      context = context |> with_agent(agent) |> Map.update!(:opts, &Keyword.put(&1, :agent_timeout_ms, 600))
      assert {:ok, _} = ExecutionSandbox.agent(context, role, "Continue", wall_timeout_ms: remaining)
      assert context.settings.check_timeout_ms == 100
    end
  end

  test "configured turn cap bounds the launcher and agent without extending remaining activity budget" do
    turn_timeout = 7_200_000
    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: turn_timeout)

    for role <- [:coder, :reviewer, :diagnosis], remaining <- [60_000, 7_671_000] do
      context = context!()
      expected = min(remaining, turn_timeout)

      agent = fn _, _, _, options ->
        assert options[:wall_timeout_ms] == expected
        environment = options[:execution_environment]
        [_, raw] = Regex.run(~r/^args = (.+)$/m, File.read!(Path.join(environment.codex_home, "environments.toml")))
        assert argv_value(Jason.decode!(raw), "--timeout-seconds") == to_string(div(expected, 1_000))
        result!(scratch(options))
        if role == :coder, do: export!(scratch(options), %{"source.txt" => "unchanged"})
        {:ok, %{output_text: "done"}}
      end

      assert {:ok, _} = ExecutionSandbox.agent(with_agent(context, agent), role, "Continue", wall_timeout_ms: remaining)
      assert context.settings.check_timeout_ms == 100
    end
  end

  test "review and diagnosis do not import their disposable changes" do
    for role <- [:reviewer, :diagnosis] do
      context = context!()

      agent = fn _, prompt, _, options ->
        assert prompt =~ "frozen base is /baseline"
        assert options[:execution_environment].read_only == true
        assert File.read!(Path.join(options[:execution_environment].codex_home, "environments.toml")) =~ "--read-only-workspace"
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

  test "complete cleanup with a failed export stops before importing and reports the export failure" do
    context = context!()

    agent = fn _, _, _, options ->
      scratch = scratch(options)
      export!(scratch, %{"source.txt" => "must not import"})
      result!(scratch)
      path = Path.join(scratch, "result.json")
      report = path |> File.read!() |> Jason.decode!() |> Map.put("export_complete", false)
      File.write!(path, Jason.encode!(report))
      {:ok, %{output_text: "passed"}}
    end

    assert {:error, :sandbox_export_incomplete} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
    assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
  end

  test "an export diagnosis still requires authentic cleanup, root and status evidence" do
    for changes <- [
          %{"cleanup_complete" => false},
          %{"scratch_root" => "/another-run"},
          %{"exit_status" => "0"},
          %{"export_complete" => "false"},
          %{"export_complete" => nil}
        ] do
      context = context!()

      agent = fn _, _, _, options ->
        scratch = scratch(options)
        export!(scratch, %{"source.txt" => "must not import"})
        result!(scratch)
        path = Path.join(scratch, "result.json")
        report = path |> File.read!() |> Jason.decode!() |> Map.put("export_complete", false) |> Map.merge(changes)
        File.write!(path, Jason.encode!(report))
        {:ok, %{output_text: "passed"}}
      end

      assert {:error, :sandbox_cleanup_incomplete} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "Repair", [])
      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
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

  test "View marker routes to the fixed trusted runner without forwarding marker arguments" do
    context = git_context!()
    log = Path.join(context.root, "view.log")

    command = fn argv, cwd, timeout, output ->
      assert cwd == context.workspace and output == log
      assert timeout > 100
      assert "/opt/toolchain/view-validation/python/bin/python" in argv
      assert "/opt/symphony/scripts/check_view_isolated.py" in argv
      refute "/baseline/scripts/check_view.py" in argv
      assert "-I" in argv and "-B" in argv
      assert "--candidate-sha" in argv
      sha = argv_value(argv, "--candidate-sha")
      assert String.length(sha) == 40
      scratch = argv_value(argv, "--scratch-root")
      export!(scratch, %{".check-evidence/view-report/gate-report.json" => "complete View gate report"})
      result!(scratch, 0)
      File.write!(output, "View gate output")
      {:ok, 0}
    end

    context = put_in(context.opts, sandbox_command_run: command, sandbox_cleanup_timeout_ms: 1)

    assert {:ok, 0} =
             ExecutionSandbox.check(
               context,
               ["python3", "/baseline/scripts/check_view.py"],
               100,
               log
             )

    assert File.read!(Path.rootname(log) <> "-details/view-report/gate-report.json") ==
             "complete View gate report"

    assert File.read!(log) == "View gate output"
  end

  test "unsupported checks never fall back to a host command" do
    context = context!()
    context = put_in(context.opts, sandbox_command_run: fn _, _, _, _ -> flunk("must not run") end)

    for command <- [
          ["mix", "test"],
          ["python3", "/trusted/other.py"],
          ["python3", "/baseline/scripts/check_view.py", "--candidate-sha", "attacker-chosen"]
        ] do
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

  test "rootless profile is frozen, requires a pinned image and keeps old defaults" do
    context = context!()
    config = context.settings.sandbox |> Map.delete(:enabled) |> Map.put("enabled", true) |> Map.drop(~w(disk_mb pids))

    rootless =
      Map.merge(config, %{
        "backend" => "rootless",
        "profile" => "rootless-open-v1",
        "network" => "public-egress-v1",
        "image" => "example/image@sha256:" <> String.duplicate("a", 64),
        "worker" => "symphony-worker"
      })

    assert {:ok, settings} = ExecutionSandbox.settings(rootless)
    assert settings["disk_mb"] == 20_480 and settings["pids"] == 512
    assert {:ok, legacy} = ExecutionSandbox.settings(config)
    assert legacy["disk_mb"] == 8192 and legacy["pids"] == 256

    for {key, value} <- [
          {"backend", "host"},
          {"image", "ubuntu:latest"},
          {"worker", "root"},
          {"environment_recipe", "../escape"},
          {"environment_recipe", 123},
          {"network", "host"},
          {"acceptance_profiles", %{"x" => %{"command" => "arbitrary"}}}
        ] do
      assert {:error, :invalid_execution_sandbox} = ExecutionSandbox.settings(Map.put(rootless, key, value))
    end
  end

  test "completed model with rejected export reports export failure independently of cleanup" do
    context = context!()

    agent = fn _, _, _, options ->
      scratch = scratch(options)
      result!(scratch)
      path = Path.join(scratch, "result.json")
      report = path |> File.read!() |> Jason.decode!() |> Map.put("export_complete", false)
      File.write!(path, Jason.encode!(report))
      {:ok, %{output_text: "completed"}}
    end

    assert {:error, :sandbox_export_incomplete} = ExecutionSandbox.agent(with_agent(context, agent), :coder, "task", [])
    assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
  end

  test "rootless preflight requires a trusted ready report from the actual launcher subprocess" do
    context = rootless_context!()
    marker = Path.join(context.root, "preflight-argv")

    for {output, status, expected} <- [
          {~s({"status":"ready","backend":"rootless"}), 0, :ok},
          {~s({"status":"blocked","backend":"rootless"}), 0, {:error, :sandbox_preflight_invalid}},
          {~s({"status":"ready","backend":"bubblewrap"}), 0, {:error, :sandbox_preflight_invalid}},
          {"not JSON", 0, :decode_error},
          {"rootless unavailable", 7, {:error, {:command_failed, 7, "rootless unavailable"}}}
        ] do
      launcher = Path.join(context.settings.sandbox["trusted_root"], "scripts/execution_sandbox.sh")
      File.write!(launcher, "printf '%s\\n' \"$@\" > '#{marker}'\nprintf '%s' '#{output}'\nexit #{status}\n")
      result = ExecutionSandbox.preflight(context)

      if expected == :decode_error do
        assert {:error, %Jason.DecodeError{}} = result
      else
        assert result == expected
      end

      args = marker |> File.read!() |> String.split("\n", trim: true)
      assert argv_value(args, "--preflight") == "true"
      assert argv_value(args, "--backend") == "rootless"
      assert Enum.take(args, -5) == ["--", "/opt/codex", "exec-server", "--listen", "stdio"]
      assert argv_value(args, "--workspace") == context.workspace
      assert argv_value(args, "--timeout-seconds") == "120"
    end

    assert :ok = ExecutionSandbox.preflight(context!())
  end

  test "preflight refuses unfrozen native role commands before launching or changing model budget" do
    for command <- ["/trusted/other-codex app-server", "bash /trusted/codex app-server", "/trusted/codex exec-server"] do
      context = rootless_context!(command)
      launcher = Path.join(context.settings.sandbox["trusted_root"], "scripts/execution_sandbox.sh")
      marker = Path.join(context.root, "must-not-launch")
      File.write!(launcher, "touch '#{marker}'\n")
      receipt = Path.join(context.root, "receipt.json")
      raw = Jason.encode!(%{"status" => "coding", "usage" => %{"agent_calls" => 2}})
      File.write!(receipt, raw)
      context = Map.put(context, :receipt, receipt)

      assert {:error, :sandbox_native_client_not_frozen} = ExecutionSandbox.preflight(context)
      refute File.exists?(marker)
      refute File.exists?(context.settings.sandbox["root"])
      assert File.read!(receipt) == raw
    end

    context = rootless_context!() |> Map.delete(:services) |> Map.delete(:models)
    assert {:error, :sandbox_native_client_not_frozen} = ExecutionSandbox.preflight(context)
    refute File.exists?(context.settings.sandbox["root"])
  end

  test "formal failure classification binds environment reports to the exact candidate and resource events" do
    for {report, resource, expected} <- [
          {:environment, %{}, {:error, {:sandbox_environment_failure, 10}}},
          {:wrong_candidate, %{}, {:ok, 10}},
          {:code, %{}, {:ok, 10}},
          {:passed, %{}, {:ok, 10}},
          {:malformed, %{}, {:ok, 10}},
          {:array, %{}, {:ok, 10}},
          {:number, %{}, {:ok, 10}},
          {:null, %{}, {:ok, 10}},
          {:invalid_identity, %{}, {:ok, 10}},
          {:missing_outcome, %{}, {:ok, 10}},
          {:invalid_outcome, %{}, {:ok, 10}},
          {:absent, [], {:ok, 10}},
          {:absent, %{"memory" => 42, "pids" => []}, {:ok, 10}},
          {:absent, %{"memory" => 42, "pids" => %{"max" => 1}}, {:error, {:sandbox_environment_failure, 10}}},
          {:absent, %{"memory" => %{"oom_kill" => "1"}}, {:ok, 10}},
          {:absent, %{"memory" => %{"oom_kill" => 1}}, {:error, {:sandbox_environment_failure, 10}}},
          {:absent, %{"pids" => %{"max" => 1}}, {:error, {:sandbox_environment_failure, 10}}},
          {:absent, %{"memory" => %{"oom_kill" => 0}, "pids" => %{"max" => 0}}, {:ok, 10}}
        ] do
      context = git_context!()
      log = Path.join(context.root, "classification.log")

      command = fn argv, _, _, _ ->
        sha = argv_value(argv, "--candidate-sha")
        scratch = argv_value(argv, "--scratch-root")
        body = %{"identity" => %{"candidate_sha" => sha}, "failure_category" => "environment", "outcome" => 10}

        files =
          case report do
            :environment -> %{".check-evidence/gate/result.json" => Jason.encode!(body)}
            :wrong_candidate -> %{".check-evidence/gate/result.json" => Jason.encode!(put_in(body, ["identity", "candidate_sha"], String.duplicate("f", 40)))}
            :code -> %{".check-evidence/gate/result.json" => Jason.encode!(Map.put(body, "failure_category", "code"))}
            :passed -> %{".check-evidence/gate/result.json" => Jason.encode!(Map.put(body, "outcome", 0))}
            :malformed -> %{".check-evidence/gate/result.json" => "broken JSON"}
            :array -> %{".check-evidence/gate/result.json" => "[]"}
            :number -> %{".check-evidence/gate/result.json" => "42"}
            :null -> %{".check-evidence/gate/result.json" => "null"}
            :invalid_identity -> %{".check-evidence/gate/result.json" => Jason.encode!(Map.put(body, "identity", 42))}
            :missing_outcome -> %{".check-evidence/gate/result.json" => Jason.encode!(Map.delete(body, "outcome"))}
            :invalid_outcome -> %{".check-evidence/gate/result.json" => Jason.encode!(Map.put(body, "outcome", "10"))}
            :absent -> %{".check-evidence/check.log" => "failed check"}
          end

        export!(scratch, files)
        result!(scratch, 10)
        path = Path.join(scratch, "result.json")
        File.write!(path, Jason.encode!(Map.put(Jason.decode!(File.read!(path)), "resource_events", resource)))
        {:ok, 10}
      end

      context = put_in(context.opts, sandbox_command_run: command, sandbox_cleanup_timeout_ms: 1)
      assert ExecutionSandbox.check(context, ["python3", "/trusted/check_candidate.py"], 100, log) == expected
      assert File.dir?(Path.rootname(log) <> "-details")

      if report in [:array, :number, :null] do
        assert File.read!(Path.rootname(log) <> "-details/gate/result.json") == %{array: "[]", number: "42", null: "null"}[report]
      end

      assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    end
  end

  test "import recovery rejects malformed proof, missing originals, nonregular files and audit mismatch without changing the scene" do
    for failure <- [:receipt_json, :journal_json, :proof_json, :missing_original, :directory, :wrong_digest, :audit] do
      {context, transaction, digest, audit} = failed_import!()

      case failure do
        :receipt_json ->
          File.write!(context.receipt, "broken JSON")

        :journal_json ->
          File.write!(Path.join(transaction, "journal.json"), "broken JSON")

        :proof_json ->
          journal = Jason.decode!(File.read!(Path.join(transaction, "journal.json")))
          File.write!(Path.join(Path.dirname(journal["export"]), "result.json"), "broken JSON")

        :missing_original ->
          File.rm!(Path.join(context.workspace, "source.txt"))

        :directory ->
          File.rm!(Path.join(context.workspace, "source.txt"))
          File.mkdir!(Path.join(context.workspace, "source.txt"))

        _ ->
          :ok
      end

      receipt_before = File.read!(context.receipt)
      journal_before = File.read!(Path.join(transaction, "journal.json"))
      source_before = File.lstat(Path.join(context.workspace, "source.txt"))

      digest =
        case failure do
          :wrong_digest -> String.duplicate("0", 64)
          :journal_json -> :crypto.hash(:sha256, journal_before) |> Base.encode16(case: :lower)
          _ -> digest
        end

      audit = if failure == :audit, do: Map.put(audit, "predecessor", "missing-predecessor"), else: audit

      assert {:error, :sandbox_import_recovery_required} = ExecutionSandbox.recover_import(context, digest, audit)
      assert File.read!(context.receipt) == receipt_before
      assert File.read!(Path.join(transaction, "journal.json")) == journal_before
      assert File.lstat(Path.join(context.workspace, "source.txt")) == source_before
      refute File.exists?(Path.join(context.evidence, "operator-rechecks/restore"))
      refute File.exists?(Path.join(context.evidence, "operator-recheck.lock"))
    end
  end

  test "a verified failed import may retain missing staged additions and archive a complete rollback" do
    {context, transaction, digest, audit} = failed_import!()
    refute File.exists?(Path.join(context.workspace, "added.txt"))
    assert :ok = ExecutionSandbox.recover_import(context, digest, audit)
    refute File.exists?(transaction)
    assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
    refute File.exists?(Path.join(context.workspace, "added.txt"))
    archived = Path.join(context.evidence, "operator-rechecks/restore/import-transaction/journal.json")
    assert File.regular?(archived)
    assert File.regular?(Path.join(context.evidence, "operator-rechecks/restore/completion.json"))
  end

  test "trusted import recovery refuses altered state and closes a verified rollback under audit" do
    for original_mode <- [0o644, 0o600], tampered <- [false, :content, :mode, :unchanged_mode] do
      context = context!()
      source = Path.join(context.workspace, "source.txt")
      # Make the journal's original mode independent of the process umask.
      File.chmod!(source, original_mode)

      agent = fn _, _, _, options ->
        export!(scratch(options), %{"source.txt" => "new"})
        result!(scratch(options))
        {:ok, %{}}
      end

      operation = fn _, _, _ -> {:error, :enospc} end
      context = context |> with_agent(agent) |> update_in([:opts], &Keyword.put(&1, :sandbox_import_file, operation))
      assert {:error, {:sandbox_import_failed, transaction, _, :ok}} = ExecutionSandbox.agent(context, :coder, "task", [])
      assert Bitwise.band(File.stat!(source).mode, 0o777) == original_mode
      receipt = Path.join(context.root, "receipt.json")
      File.write!(receipt, Jason.encode!(%{"status" => "blocked", "rounds" => [%{"evidence" => Path.join(context.evidence, "round-1")}]}))
      context = context |> Map.put(:receipt, receipt) |> put_in([:settings, :checks], [["true"]])
      digest = :crypto.hash(:sha256, File.read!(Path.join(transaction, "journal.json"))) |> Base.encode16(case: :lower)

      audit = %{
        "id" => "restore",
        "authorization" => "Authorized recovery",
        "runtime_version" => String.duplicate("a", 40),
        "command" => ["recover_import"],
        "predecessor" => nil,
        "legacy_closures" => []
      }

      if tampered in [:content, :mode] do
        case tampered do
          :content ->
            File.write!(source, "another actor")

          :mode ->
            changed_mode = if original_mode == 0o644, do: 0o600, else: 0o644
            File.chmod!(source, changed_mode)
            assert Bitwise.band(File.stat!(source).mode, 0o777) == changed_mode
        end

        assert {:error, :sandbox_import_recovery_required} = ExecutionSandbox.recover_import(context, digest, audit)
        assert File.dir?(transaction)
        refute File.exists?(Path.join(context.evidence, "operator-rechecks/restore"))
      else
        # Reapplying the journal's mode is not a change to the frozen identity.
        if tampered == :unchanged_mode, do: File.chmod!(source, original_mode)
        assert :ok = ExecutionSandbox.recover_import(context, digest, audit)
        refute File.exists?(transaction)
        assert File.regular?(Path.join(context.evidence, "operator-rechecks/restore/completion.json"))
        assert File.read!(Path.join(context.workspace, "source.txt")) == "original"
        assert Bitwise.band(File.stat!(source).mode, 0o777) == original_mode
      end
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

  defp rootless_context!(command \\ nil) do
    context = context!()

    for name <- ["GH12_CODER_KEY", "GH12_REVIEWER_KEY"] do
      previous = System.get_env(name)
      System.put_env(name, "synthetic-preflight-account")
      on_exit(fn -> restore_env(name, previous) end)
    end

    trusted = Path.join(context.root, "trusted")
    File.mkdir_p!(Path.join(trusted, "scripts"))

    config =
      Map.merge(context.settings.sandbox, %{
        "backend" => "rootless",
        "profile" => "rootless-open-v1",
        "network" => "public-egress-v1",
        "image" => "fixture@sha256:" <> String.duplicate("a", 64),
        "worker" => "fixture-worker",
        "trusted_root" => trusted,
        "codex" => Path.join(trusted, "codex")
      })

    settings = ModelFixture.settings(Path.join(context.root, "authority")) |> Map.put(:sandbox, config) |> Map.put(:model_command, command || config["codex"] <> " app-server")

    registry =
      Enum.reduce([{:coder, "coding"}, {:reviewer, "reviewing"}], settings.model_services, fn {role, id}, registry ->
        {:ok, service} = ModelServices.snapshot(%{settings | model_services: registry}, id, role, "fixture")
        {:ok, registry} = ModelCatalog.attest(registry, service, ModelFixture.proof(role))
        registry
      end)

    settings = %{settings | model_services: registry}
    ModelFixture.write_authority!(settings)

    services =
      Map.new([{:coder, "coding"}, {:reviewer, "reviewing"}], fn {role, id} ->
        {:ok, service} = ModelServices.snapshot(settings, id, role, "fixture")
        {Atom.to_string(role), service}
      end)

    %{context | settings: settings} |> Map.put(:services, services)
  end

  defp failed_import! do
    context = context!()

    agent = fn _, _, _, options ->
      export!(scratch(options), %{"source.txt" => "new", "added.txt" => "new addition"})
      result!(scratch(options))
      {:ok, %{}}
    end

    context = context |> with_agent(agent) |> update_in([:opts], &Keyword.put(&1, :sandbox_import_file, fn _, _, _ -> {:error, :enospc} end))
    assert {:error, {:sandbox_import_failed, transaction, _, :ok}} = ExecutionSandbox.agent(context, :coder, "task", [])
    receipt = Path.join(context.root, "receipt.json")
    File.write!(receipt, Jason.encode!(%{"status" => "blocked", "rounds" => [%{"evidence" => Path.join(context.evidence, "round-1")}]}))
    context = context |> Map.put(:receipt, receipt) |> put_in([:settings, :checks], [["true"]])
    digest = :crypto.hash(:sha256, File.read!(Path.join(transaction, "journal.json"))) |> Base.encode16(case: :lower)

    audit = %{
      "id" => "restore",
      "authorization" => "Authorized recovery",
      "runtime_version" => String.duplicate("a", 40),
      "command" => ["recover_import"],
      "predecessor" => nil,
      "legacy_closures" => []
    }

    {context, transaction, digest, audit}
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
