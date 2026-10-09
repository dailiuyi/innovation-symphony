defmodule SymphonyElixir.Mvp.ExecutionReadinessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.{AutomaticAcceptance, ModelServices}
  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.ExecutionReadiness, as: Readiness
  alias SymphonyElixir.Workflow

  setup do
    home = Path.join(System.tmp_dir!(), "readiness-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"OPENAI_API_KEY" => "synthetic-test-only"}))
    Process.put(:readiness_test_home, home)
    on_exit(fn -> File.rm_rf!(home) end)
    :ok
  end

  defp settings do
    %{
      workflow_path: "/tmp/WORKFLOW.md",
      execution_workspace_root: "/tmp/workspaces",
      state_dir: "/tmp/state",
      execution_readiness: %{enabled: true, required_backend: "rootless", required_acceptances: []},
      checks: [["python3", "{baseline}/scripts/check_candidate.py", "{workspace}"], ["python3", "scripts/check_baseline.py"]],
      recovery: %{enabled: true},
      sandbox: %{
        :enabled => true,
        "backend" => "rootless",
        "profile" => "rootless-open-v1",
        "network" => "public-egress-v1",
        "root" => "/tmp/sandboxes",
        "trusted_root" => "/opt/trusted",
        "codex" => "/opt/codex",
        "toolchain" => "/opt/toolchain",
        "dependencies" => "/opt/dependencies",
        "image" => "ubuntu@sha256:" <> String.duplicate("a", 64),
        "worker" => "worker",
        "memory_mb" => 4096,
        "disk_mb" => 20_480,
        "pids" => 512,
        "cpus" => 4
      }
    }
  end

  defp models do
    home = Process.get(:readiness_test_home)
    {:ok, identity} = ModelServices.credential_identity("auth_home:" <> home)

    service = %{
      "credential_ref" => "auth_home:" <> home,
      "credential_identity" => identity,
      "command" => "/opt/codex app-server",
      "provider" => "openai",
      "connection" => %{"base_url" => "https://api.example.test/v1", "wire_api" => "responses"}
    }

    %{coder: "gpt-coder", reviewer: "gpt-reviewer", services: %{"coder" => Map.put(service, "model", "gpt-coder"), "reviewer" => Map.put(service, "model", "gpt-reviewer")}}
  end

  defp role_options(context, role), do: {:ok, [model_service: context.services[Atom.to_string(role)]]}

  defp report(raw, fields \\ %{}) do
    Map.merge(
      %{
        "schema" => 1,
        "status" => "ready",
        "backend" => "rootless",
        "profile" => "rootless-open-v1",
        "request_sha256" => :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
        "formal_acceptance" => false,
        "checks" => Enum.map(~w(task_roots trusted_inventory toolchain runtime image), &%{"name" => &1, "status" => "passed", "detail" => "present"}),
        "blockers" => []
      },
      fields
    )
    |> Jason.encode!()
  end

  test "ready admission freezes the selected roles once and default preflight uses the same checks" do
    value =
      Map.merge(settings(), %{
        enabled: true,
        ready_label: "ready",
        allowed_actors: ["alice"],
        allowed_models: ["gpt-coder", "gpt-reviewer"],
        coder_model: "gpt-coder",
        reviewer_model: "gpt-reviewer",
        model_command: "/opt/codex app-server"
      })

    value = put_in(value, [:sandbox, "auth_home"], Process.get(:readiness_test_home))
    issue = %{state: "open", labels: ["ready"], repo: "owner/repo", number: 1}

    request = fn "GET", path, _, nil, _ ->
      send(self(), {:intake, path})
      events = [%{"id" => 1, "event" => "labeled", "label" => %{"name" => "ready"}, "actor" => %{"login" => "alice"}}]
      {:ok, %{status: 200, body: if(String.ends_with?(path, "/events"), do: events, else: [])}}
    end

    runner = fn [_, _, _, raw], _, _ -> {:ok, report(raw)} end

    opts = [
      request_fun: request,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "synthetic-test-token"}},
      readiness_role_options: &role_options/2,
      readiness_command_run: runner
    ]

    assert {:ok, %{services: services, readiness: %{"status" => "ready"}}} = Readiness.prepare(issue, value, opts)
    assert services["coder"]["model"] == "gpt-coder"
    assert services["reviewer"]["model"] == "gpt-reviewer"
    assert_received {:intake, "/repos/owner/repo/issues/1/events"}
    assert_received {:intake, "/repos/owner/repo/issues/1/comments"}
    assert :ok = Readiness.defaults(value, opts)
    refute_received {:intake, _}
    assert {:error, {:execution_readiness_role, :coder, _}} = Readiness.check(value, %{coder: "gpt-coder", reviewer: "gpt-reviewer", services: services})
  end

  test "registered exact runners pass and stale evidence or unsupported probe roles stop admission" do
    value = settings()
    home = Process.get(:readiness_test_home)
    File.mkdir_p!(Path.join(home, "scripts"))
    File.write!(Path.join(home, "scripts/probe_rootless.py"), "fixed probe")
    value = put_in(value, [:sandbox, "trusted_root"], home)
    kinds = ~w(linux gpt_coder gpt_reviewer)

    profiles =
      Map.new(kinds, fn kind ->
        {:ok, sha} = AutomaticAcceptance.runner_digest(%{settings: value}, kind)
        {kind, %{"kind" => kind, "runner_sha256" => sha, "timeout_ms" => 60_000}}
      end)

    value = put_in(value, [:execution_readiness, :required_acceptances], kinds)
    value = put_in(value, [:sandbox, "acceptance_profiles"], profiles)
    runner = fn [_, _, _, raw], _, _ -> {:ok, report(raw)} end
    opts = [readiness_role_options: &role_options/2, readiness_command_run: runner]
    assert {:ok, _} = Readiness.check(value, models(), opts)
    unsupported = put_in(models(), [:services, "coder", "model"], "deepseek-test")
    assert {:error, {:execution_readiness_acceptance_unavailable, "gpt_coder"}} = Readiness.check(value, unsupported, opts)
    File.write!(Path.join(home, "scripts/probe_rootless.py"), "changed probe")
    assert {:error, {:execution_readiness_acceptance_unavailable, "linux"}} = Readiness.check(value, models(), opts)
  end

  test "the required backend cannot fall back to legacy or disabled execution" do
    for sandbox <- [%{enabled: false}, Map.put(settings().sandbox, "backend", "bubblewrap")] do
      value = %{settings() | sandbox: sandbox}
      refute Readiness.backend_ready?(value)
      assert {:error, :execution_readiness_backend_mismatch} = Readiness.prepare(%{}, value, [])
      assert {:error, :execution_readiness_backend_mismatch} = Readiness.defaults(value, [])
    end

    assert Readiness.backend_ready?(%{})
    assert {:ok, nil} = Readiness.prepare(%{}, %{}, [])
    assert :ok = Readiness.defaults(%{}, [])
  end

  test "strict opt-in configuration rejects unspecified backends and malformed acceptance lists" do
    assert {:ok, %{enabled: false}} = Readiness.settings(nil)
    assert {:ok, %{enabled: false}} = Readiness.settings(%{"enabled" => false})
    valid = %{"enabled" => true, "required_backend" => "rootless", "required_acceptances" => ["A01"]}
    assert {:ok, %{required_acceptances: ["A01"]}} = Readiness.settings(valid)

    for value <- [
          true,
          %{},
          Map.put(valid, "required_backend", "bubblewrap"),
          Map.put(valid, "extra", true),
          Map.put(valid, "required_acceptances", ["A01", "A01"]),
          Map.put(valid, "required_acceptances", [nil]),
          Map.put(valid, "required_acceptances", "A01"),
          %{"enabled" => false, "extra" => true}
        ] do
      assert {:error, :invalid_execution_readiness} = Readiness.settings(value)
    end
  end

  test "readiness binds the report to exact roots, resource policy and check kinds without sending credentials" do
    runner = fn ["bash", "/opt/trusted/scripts/execution_sandbox.sh", "--readiness", raw], "/tmp", 60_000 ->
      request = Jason.decode!(raw)
      assert request["checks"] == ["candidate", "baseline"]
      assert request["workspace_root"] == "/tmp/workspaces"
      assert request["sandbox"]["environment_recipe"] == ""
      refute Map.has_key?(request["sandbox"], "auth_home")
      {:ok, report(raw)}
    end

    assert {:ok, %{"status" => "ready", "formal_acceptance" => false, "services_sha256" => sha}} =
             Readiness.check(settings(), models(), readiness_role_options: &role_options/2, readiness_command_run: runner)

    assert byte_size(sha) == 64
  end

  test "the default bridge runner scrubs explicitly loaded GitHub secrets without a runtime workflow store" do
    root = Process.get(:readiness_test_home)
    trusted = Path.join(root, "trusted")
    File.mkdir_p!(Path.join(trusted, "scripts"))
    script = Path.join(root, "readiness-report.py")

    File.write!(script, """
    import hashlib, json, os, sys
    assert os.environ.get('LOADED_READINESS_TOKEN') is None
    assert os.environ.get('GITHUB_TOKEN') is None
    raw = sys.argv[1]
    print(json.dumps(dict(schema=1, status='ready', backend='rootless', profile='rootless-open-v1',
      request_sha256=hashlib.sha256(raw.encode()).hexdigest(), formal_acceptance=False, blockers=[],
      checks=[dict(name=name, status='passed', detail='synthetic inventory fixture') for name in
        ('task_roots', 'trusted_inventory', 'toolchain', 'runtime', 'image')])))
    """)

    File.write!(Path.join(trusted, "scripts/execution_sandbox.sh"), "#!/bin/bash\nexec python3 -I -B #{inspect(script)} \"$2\"\n")
    value = settings()
    sandbox = value.sandbox |> Map.delete(:enabled) |> Map.put("enabled", true) |> Map.put("trusted_root", trusted) |> Map.put("auth_home", root)

    config = %{
      "tracker" => %{"kind" => "github", "provider" => %{"repo" => "owner/repo", "token" => "$LOADED_READINESS_TOKEN"}, "required_labels" => ["ready"]},
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "codex" => %{"command" => "/opt/codex app-server"},
      "mvp" => %{
        "enabled" => true,
        "coder_model" => "gpt-coder",
        "reviewer_model" => "gpt-reviewer",
        "allowed_models" => ["gpt-coder", "gpt-reviewer"],
        "allowed_actors" => ["alice"],
        "checks" => [["python3", "scripts/check_candidate.py"]],
        "state_dir" => Path.join(root, "state"),
        "sandbox" => sandbox,
        "execution_readiness" => %{"enabled" => true, "required_backend" => "rootless", "required_acceptances" => []}
      }
    }

    workflow = Path.join(root, "LOADED-WORKFLOW.md")
    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nExplicit workflow fixture\n")
    services = Path.join(root, "models.json")
    File.write!(services, Jason.encode!(models().services))

    code = """
    alias SymphonyElixir.{Workflow, WorkflowStore, AgentRuntimeSupervisor, TaskSupervisor, Orchestrator}
    alias SymphonyElixir.Mvp.{Config, ExecutionReadiness}
    [path, services_path] = System.argv()
    original_path = Workflow.workflow_file_path()
    {:ok, workflow} = Workflow.load(path)
    {:ok, settings} = Config.settings(workflow, Path.dirname(path))
    true = "LOADED_READINESS_TOKEN" in settings.secret_environment_names
    services = services_path |> File.read!() |> Jason.decode!()
    models = %{coder: "gpt-coder", reviewer: "gpt-reviewer", services: services}
    resolver = fn context, role -> {:ok, [model_service: context.services[Atom.to_string(role)]]} end
    {:ok, %{"status" => "ready"}} = ExecutionReadiness.check(settings, models, readiness_role_options: resolver)
    for name <- [WorkflowStore, AgentRuntimeSupervisor, TaskSupervisor, Orchestrator], do: nil = Process.whereis(name)
    true = original_path == Workflow.workflow_file_path()
    IO.puts("loaded tracker snapshot and default command runner passed")
    """

    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    env = [{"LOADED_READINESS_TOKEN", "synthetic-loaded-token"}, {"GITHUB_TOKEN", "synthetic-global-token"}, {"LINEAR_API_KEY", nil}, {"LINEAR_API_TOKEN", nil}]
    {output, status} = System.cmd("elixir", code_paths ++ ["-e", code, workflow, services], env: env, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "loaded tracker snapshot and default command runner passed"
    {:ok, loaded} = Workflow.load(workflow)
    {:ok, loaded_settings} = MvpConfig.settings(loaded, Path.dirname(workflow))
    assert {:ok, %{"status" => "ready"}} = Readiness.check(loaded_settings, models(), readiness_role_options: &role_options/2)
    refute File.exists?(Path.join(root, "state"))
    refute File.exists?(Path.join(root, "workspaces"))
  end

  test "missing role credentials or mismatched native commands stop before any bridge request" do
    resolvers = [
      fn _, _ -> {:error, :model_credential_missing} end,
      fn _, _ -> {:ok, []} end,
      fn _, _ -> {:ok, [model_service: %{"command" => "wrapper app-server"}]} end
    ]

    for resolver <- resolvers do
      assert {:error, {:execution_readiness_role, :coder, _}} =
               Readiness.check(settings(), models(), readiness_role_options: resolver, readiness_command_run: fn _, _, _ -> flunk("must not run") end)
    end
  end

  test "default readiness returns at its deadline when an exited command leaves stdout held open" do
    root = Process.get(:readiness_test_home)
    scripts = Path.join(root, "scripts")
    File.mkdir_p!(scripts)
    holder = Path.join(root, "holder.pid")
    launcher = Path.join(root, "launcher.pid")
    release = Path.join(root, "release")
    python = Path.join(root, "held-output.py")

    File.write!(python, """
    import os, pathlib, time
    pathlib.Path(#{inspect(launcher)}).write_text(str(os.getpid()))
    if os.fork() == 0:
        pathlib.Path(#{inspect(holder)}).write_text(str(os.getpid()))
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not pathlib.Path(#{inspect(release)}).exists():
            time.sleep(0.01)
        os._exit(0)
    os._exit(0)
    """)

    File.write!(Path.join(scripts, "execution_sandbox.sh"), "#!/bin/bash\nexec python3 -I -B #{inspect(python)}\n")
    on_exit(fn -> File.write!(release, "release fixture child") end)
    value = settings() |> put_in([:sandbox, "trusted_root"], root) |> Map.put(:secret_environment_names, [])
    started = System.monotonic_time(:millisecond)

    assert {:error, {:execution_readiness_timeout, 1_000}} =
             Readiness.check(value, models(), readiness_role_options: &role_options/2, readiness_timeout_ms: 1_000)

    assert System.monotonic_time(:millisecond) - started < 3_000
    refute File.exists?("/proc/#{File.read!(launcher)}")
    assert File.exists?("/proc/#{File.read!(holder)}")

    assert {:error, :execution_readiness_invalid_timeout} =
             Readiness.check(value, models(), readiness_role_options: &role_options/2, readiness_timeout_ms: 0)

    bad_cwd = Map.put(value, :workflow_path, Path.join([root, "missing-working-directory", "WORKFLOW.md"]))

    assert {:error, {:command_failed, _, _}} =
             Readiness.check(bad_cwd, models(), readiness_role_options: &role_options/2)

    invalid_environment = Map.put(value, :secret_environment_names, [nil])

    assert {:error, :execution_readiness_bridge_failed} =
             Readiness.check(invalid_environment, models(), readiness_role_options: &role_options/2)

    assert Process.alive?(self())
  end

  test "legacy service exemptions cannot admit missing credentials or incompatible routes" do
    value = models()
    missing = Map.merge(value.services["coder"], %{"source" => "legacy_migration", "credential_identity" => nil, "credential_ref" => "auth_home:/nonexistent/readiness-auth"})
    resolver = fn _, _ -> {:ok, [model_service: missing]} end

    assert {:error, {:execution_readiness_role, :coder, :model_credential_missing}} =
             Readiness.check(settings(), value, readiness_role_options: resolver)

    incompatible = Map.put(value.services["coder"], "provider", "deepseek")

    assert {:error, {:execution_readiness_role, :coder, :model_auth_route_incompatible}} =
             Readiness.check(settings(), value, readiness_role_options: fn _, _ -> {:ok, [model_service: incompatible]} end)
  end

  test "missing or stale automatic acceptance profiles stop before bridge execution" do
    value = put_in(settings(), [:execution_readiness, :required_acceptances], ["A01"])
    assert {:error, {:execution_readiness_acceptance_unavailable, "A01"}} = Readiness.check(value, models(), readiness_role_options: &role_options/2)
    value = put_in(value, [:recovery, :enabled], false)
    assert {:error, :execution_readiness_requires_recovery} = Readiness.check(value, models(), readiness_role_options: &role_options/2)
  end

  test "invalid, stale, failing and empty reports never admit a task" do
    for fields <- [
          %{"request_sha256" => String.duplicate("0", 64)},
          %{"schema" => 2},
          %{"formal_acceptance" => true},
          %{"checks" => []},
          %{"checks" => [nil]},
          %{"checks" => [%{"name" => "image", "status" => "passed", "detail" => "present"}]},
          %{"checks" => [%{"status" => "failed"}]},
          %{"blockers" => ["missing"]}
        ] do
      assert {:error, :execution_readiness_invalid_report} =
               Readiness.check(settings(), models(),
                 readiness_role_options: &role_options/2,
                 readiness_command_run: fn [_, _, _, raw], _, _ -> {:ok, report(raw, fields)} end
               )
    end

    blockers = [%{"name" => "image", "detail" => "image missing"}]

    assert {:error, {:execution_readiness_blocked, ^blockers}} =
             Readiness.check(settings(), models(),
               readiness_role_options: &role_options/2,
               readiness_command_run: fn [_, _, _, raw], _, _ -> {:ok, report(raw, %{"status" => "blocked", "blockers" => blockers})} end
             )

    for result <- [{:ok, "not json"}, {:error, :timeout}] do
      assert {:error, _} = Readiness.check(settings(), models(), readiness_role_options: &role_options/2, readiness_command_run: fn _, _, _ -> result end)
    end

    value = %{settings() | checks: [["bash", "custom.sh"]]}
    assert {:error, :execution_readiness_unsupported_check} = Readiness.check(value, models(), readiness_role_options: &role_options/2)
  end
end
