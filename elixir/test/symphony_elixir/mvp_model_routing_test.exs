defmodule SymphonyElixir.MvpModelRoutingTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp.{Intake, ModelCatalog, ModelServices}

  setup do
    root = Path.join(System.tmp_dir!(), "gh12-routing-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/issue")
    File.mkdir_p!(workspace)
    System.put_env("GH12_CODER_KEY", "synthetic-route-coder")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-route-reviewer")
    binary = Path.join(root, "server.py")
    write_server(binary)
    workflow_opts = [workspace_root: Path.dirname(workspace), codex_command: "must-not-be-used", codex_read_timeout_ms: 1000]
    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)

    on_exit(fn ->
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
      File.rm_rf!(root)
    end)

    issue = %{id: "gh12", identifier: "GH-12", title: "Routing test"}
    %{root: root, workspace: workspace, settings: F.settings(root), binary: binary, issue: issue}
  end

  test "concurrent actual AppServer subprocesses use independent home, credentials, URLs and efforts", c do
    original_url = System.get_env("OPENAI_BASE_URL")
    System.put_env("OPENAI_BASE_URL", "https://inherited-wrong.example/v1")

    on_exit(fn ->
      if original_url, do: System.put_env("OPENAI_BASE_URL", original_url), else: System.delete_env("OPENAI_BASE_URL")
    end)

    File.mkdir!(Path.join(c.workspace, ".codex"))
    File.write!(Path.join(c.workspace, ".codex/config.toml"), "candidate-controlled poison")

    jobs =
      Enum.map([{:coder, "coding"}, {:reviewer, "reviewing"}], fn {role, id} ->
        trace = Path.join(c.root, "#{role}.json")
        {:ok, service} = ModelServices.snapshot(c.settings, id, role, "fixture")
        service = Map.put(service, "command", "python3 #{c.binary} #{trace} success")
        {service, trace, Task.async(fn -> ModelServices.run(c.workspace, "test", c.issue, model: "gpt-test", model_service: service, read_only: role == :reviewer, tools: false) end)}
      end)

    for {service, trace, task} <- jobs do
      assert {:ok, result} = Task.await(task)
      assert is_nil(result.actual_model)
      assert result.output_text == "{\"ok\":true}"
      data = trace |> File.read!() |> Jason.decode!()
      assert data["config"] =~ service["connection"]["base_url"]
      assert is_nil(data["base_url_environment"])
      assert data["config"] =~ service["parameters"]["reasoning_effort"]
      assert data["credential_hash"] == hash(if service["role"] == "coder", do: "synthetic-route-coder", else: "synthetic-route-reviewer")
      refute data["config"] =~ "synthetic-route"
      refute data["config"] =~ "poison"
      refute File.exists?(data["home"])
      turn = Enum.find(data["requests"], &(&1["method"] == "turn/start"))["params"]
      assert turn["model"] == "gpt-test"
      assert turn["effort"] == service["parameters"]["reasoning_effort"]
      if service["role"] == "reviewer", do: assert(turn["sandboxPolicy"] == %{"type" => "readOnly"})
      refute System.get_env("SYMPHONY_MODEL_KEY")
      assert SymphonyElixir.Config.settings!().codex.command == "must-not-be-used"
    end
  end

  test "malformed or mismatched services and missing credentials refuse startup", c do
    {:ok, service} = ModelServices.snapshot(c.settings, "coding", :coder, "fixture")
    invalid = [model: "gpt-test", model_service: %{}]
    assert {:error, :invalid_model_service_snapshot} = AppServer.start_session(c.workspace, invalid)
    mismatch = [model: "gpt-other", model_service: service]
    assert {:error, :model_service_model_mismatch} = AppServer.start_session(c.workspace, mismatch)
    foreign_provider = [model: "gpt-test", model_service: Map.put(service, "provider", "deepseek")]
    assert {:error, :model_provider_not_supported} = AppServer.start_session(c.workspace, foreign_provider)
    remote = [worker_host: "remote", model: "gpt-test", model_service: service]
    assert {:error, :model_provider_not_supported} = AppServer.start_session(c.workspace, remote)
    System.delete_env("GH12_CODER_KEY")
    assert {:error, :model_credential_missing} = AppServer.start_session(c.workspace, model: "gpt-test", model_service: service)
  end

  test "provider errors and stderr cannot leak credential values to output, events or logs", c do
    trace = Path.join(c.root, "error.json")
    {:ok, service} = ModelServices.snapshot(c.settings, "coding", :coder, "fixture")
    service = Map.put(service, "command", "python3 #{c.binary} #{trace} error")
    parent = self()

    log =
      capture_log(fn ->
        result = AppServer.run(c.workspace, "test", c.issue, model: "gpt-test", model_service: service, tools: false, on_message: fn msg -> send(parent, {:event, msg}) end)
        assert {:error, {:turn_failed, params}} = result
        refute inspect(params) =~ "synthetic-route-coder"
        assert inspect(params) =~ "[redacted]"
      end)

    refute log =~ "synthetic-route-coder"
    events = drain_events([])
    refute inspect(events) =~ "synthetic-route-coder"
    assert events != []
  end

  test "account discovery paginates hidden entries and rejects repeated cursors or malformed pages", c do
    for {mode, expected} <- [{"success", :ok}, {"cycle", :error}, {"malformed", :error}] do
      trace = Path.join(c.root, "#{mode}.json")
      {:ok, service} = ModelServices.snapshot(c.settings, "coding", :coder, "fixture")
      service = Map.put(service, "command", "python3 #{c.binary} #{trace} #{mode}")

      case expected do
        :ok ->
          assert {:ok, models} = AppServer.list_models(service)
          assert Enum.map(models, & &1["model"]) == ["gpt-test", "gpt-next"]

        :error ->
          assert {:error, _} = AppServer.list_models(service)
      end

      requests = trace |> File.read!() |> Jason.decode!() |> Map.fetch!("requests")
      lists = Enum.filter(requests, &(&1["method"] == "model/list"))
      assert Enum.all?(lists, & &1["params"]["includeHidden"])
      refute Enum.any?(requests, &(&1["method"] == "thread/start"))
    end
  end

  test "local catalog discovery uses AppServer and refuses inference without the kernel sandbox", c do
    alias Mix.Tasks.Mvp.Models
    trace = Path.join(c.root, "managed.json")
    s = %{c.settings | model_command: "python3 #{c.binary} #{trace} probe"}
    assert {:ok, discovered} = Models.execute("refresh", s, ["coding"])
    assert discovered["catalog"]["coding"]["models"]["gpt-next"]
    {:ok, registry} = ModelServices.load(ModelServices.path(s), nil)
    s = %{s | model_services: registry}
    assert {:error, :model_probe_sandbox_required} = Models.execute("verify", s, ["coding", "gpt-test", "coder", c.workspace])
    refute File.read!(trace) =~ "turn/start"
    assert Path.wildcard(Path.join(c.workspace, "model-capability-probe-*")) == []
  end

  test "management run binds its requested workflow before real AppServer discovery", c do
    alias Mix.Tasks.Mvp.Models
    trace = Path.join(c.root, "entrypoint.json")
    file = Path.join(c.root, "MODELS.md")
    {:ok, workflow} = Workflow.current()

    config =
      workflow.config
      |> put_in(["workspace", "root"], Path.dirname(c.workspace))
      |> put_in(["codex", "command"], "python3 #{c.binary} #{trace} success")
      |> put_in(["tracker", "required_labels"], ["ready"])
      |> Map.put("mvp", %{
        "enabled" => true,
        "state_dir" => Path.join(c.root, "state"),
        "coder_model" => "gpt-test",
        "reviewer_model" => "gpt-test",
        "allowed_models" => ["gpt-test"],
        "allowed_actors" => ["owner"],
        "checks" => [["true"]],
        "model_services" => c.settings.model_services
      })

    File.write!(file, "---\n#{Jason.encode!(config)}\n---\nProbe\n")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(c.root, "wrong-root"), codex_command: "must-not-be-used")
    output = ExUnit.CaptureIO.capture_io(fn -> Models.run(["refresh", file, "coding"]) end)
    assert Jason.decode!(output)["catalog"]["coding"]["models"]["gpt-next"]
    assert Workflow.workflow_file_path() == file
    assert Config.settings!().workspace.root == Path.dirname(c.workspace)
    assert File.read!(trace) =~ "model/list"
    assert_raise Mix.Error, ~r/Cannot load/, fn -> Models.run(["show", Workflow.workflow_file_path() <> ".absent"]) end
  end

  test "legacy claim preserves the effective custom channel, credential reference and effort in actual calls", c do
    home = Path.join(c.root, "legacy-home")
    File.mkdir!(home)

    File.write!(
      Path.join(home, "config.toml"),
      ~s(model_provider = "company"\nmodel_reasoning_effort = "low"\n[model_providers.company]\nname = "Company"\nbase_url = "https://legacy.example/v1"\nwire_api = "responses"\nenv_key = "GH12_CODER_KEY"\n)
    )

    settings = c.settings |> Map.put(:model_services, nil) |> Map.put(:sandbox, %{"auth_home" => home})
    assert {:ok, models} = Intake.resolve_comments([F.comment(1, "/symphony models reviewer=gpt-test")], settings)
    assert {:ok, services} = ModelServices.freeze(models, settings)
    File.write!(Path.join(home, "config.toml"), ~s(model_reasoning_effort = "high"\n))

    for role <- ~w(coder reviewer) do
      service = services[role]
      assert service["parameters"] == %{"reasoning_effort" => "low"}
      assert service["credential_ref"] == "env:GH12_CODER_KEY"
      trace = Path.join(c.root, "legacy-#{role}.json")
      service = Map.put(service, "command", "python3 #{c.binary} #{trace} success")
      assert {:ok, _} = ModelServices.run(c.workspace, "test", c.issue, model: "gpt-test", model_service: service)
      data = trace |> File.read!() |> Jason.decode!()
      assert data["config"] =~ "https://legacy.example/v1"
      assert data["credential_hash"] == hash("synthetic-route-coder")
      turn = Enum.find(data["requests"], &(&1["method"] == "turn/start"))
      assert turn["params"]["effort"] == "low"
    end

    for raw <- [
          "model_reasoning_effort = \"ultra\"",
          "profile = \"production\"",
          "[model_providers.openai]\nhttp_headers = {Authorization = \"secret\"}",
          "model_reasoning_effort = \"low\"\nmodel_reasoning_effort = \"high\"",
          "[profiles.prod]\nmodel = \"gpt-test\""
        ] do
      File.write!(Path.join(home, "config.toml"), raw)
      assert {:error, :legacy_model_service_migration_required} = ModelServices.freeze(models, settings)
    end
  end

  test "routing overrides cannot start either role or bypass the frozen home", c do
    for suffix <- [
          ~s(--config 'model_providers.symphony.base_url="https://wrong.example"'),
          "-c model_provider=wrong",
          "--profile wrong",
          "-pwrong",
          "--model wrong",
          "CODEX_HOME=/wrong",
          "--config=model_providers.symphony.env_key=WRONG_KEY",
          ~s('--config' 'model_''provider=wrong'),
          ~S($ROUTING_FLAGS)
        ] do
      settings = %{c.settings | model_command: "codex app-server #{suffix}"}

      for role <- [:coder, :reviewer] do
        assert {:error, :model_service_command_unsafe} = ModelServices.snapshot(settings, "coding", role, "fixture")
        {:ok, service} = ModelServices.snapshot(c.settings, "coding", role, "fixture")
        service = Map.put(service, "command", settings.model_command)

        assert {:error, :invalid_model_service_snapshot} =
                 AppServer.start_session(c.workspace, model: "gpt-test", model_service: service)
      end
    end
  end

  test "real Turn errors reject prior valid output and classify server revocation and recoverable errors", c do
    for {mode, category} <- [
          {"401", :model_account_forbidden},
          {"403", :model_account_forbidden},
          {"429", :model_rate_limited},
          {"503", :model_service_unavailable},
          {"quota", :model_quota_exhausted},
          {"interrupted", :interrupted},
          {"malformed-turn", :malformed},
          {"null-turn", :malformed},
          {"bad-params", :malformed},
          {"missing-status", :malformed},
          {"completed-error", :model_account_forbidden},
          {"legacy-error", :model_account_forbidden}
        ] do
      {:ok, service} = ModelServices.snapshot(c.settings, "reviewing", :reviewer, "fixture")
      service = Map.put(service, "command", "python3 #{c.binary} #{c.root}/terminal.json #{mode}")
      result = AppServer.run(c.workspace, "test", c.issue, model: "gpt-test", model_service: service, read_only: true, tools: false)

      case category do
        :interrupted -> assert {:error, {:turn_cancelled, _}} = result
        :malformed -> assert {:error, :invalid_turn_completion} = result
        _ -> assert result == {:error, {:model_call_failed, category}}
      end
    end
  end

  test "capability probe with correct tool and JSON still rejects failed or interrupted Turn", c do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: c.root)

    for mode <- ["probe-401", "probe-interrupted"] do
      trace = Path.join(c.root, "#{mode}.json")
      settings = %{c.settings | model_command: "python3 #{c.binary} #{trace} #{mode}"}
      {settings, workspace} = F.probe_settings(settings, c.root)
      System.put_env("GH12_PROBE_WORKSPACE", workspace)
      on_exit(fn -> System.delete_env("GH12_PROBE_WORKSPACE") end)
      before = settings.model_services["validations"]
      assert {:error, _} = ModelCatalog.verify(settings, "coding", "gpt-test", :coder, workspace, probe: F.sandbox_probe(&AppServer.run/4))
      assert settings.model_services["validations"] == before
      {:ok, service} = ModelServices.snapshot(settings, "coding", :coder, "catalog")
      refute ModelCatalog.status(settings.model_services, service)["state"] == "available"
      assert File.read!(trace) =~ "turn/start"
    end
  end

  test "execution attempts stop on protocol permissions and quota but retry transient errors within original budgets", c do
    alias SymphonyElixir.Mvp.{Attempts, Receipt, Recovery}

    for {mode, category, calls} <- [
          {"401", :model_account_forbidden, 1},
          {"quota", :model_quota_exhausted, 1},
          {"429", :model_rate_limited, 2},
          {"503", :model_service_unavailable, 2}
        ] do
      receipt = Path.join(c.root, "attempts-#{mode}.json")
      evidence = receipt <> ".evidence"
      File.mkdir_p!(evidence)
      settings = %{c.settings | model_command: "python3 #{c.binary} #{c.root}/attempt-#{mode}.json #{mode}"}
      {:ok, recovery} = Recovery.settings(%{"enabled" => true, "stage_attempts" => 2, "max_agent_attempts" => 2})
      settings = Map.put(settings, :recovery, recovery)
      # The execution command is part of the binding; independently authorize this fixture.
      {:ok, service} = ModelServices.snapshot(settings, "reviewing", :reviewer, "fixture")
      {:ok, registry} = ModelCatalog.attest(settings.model_services, service, F.proof(:reviewer))
      settings = %{settings | model_services: registry}
      {:ok, service} = ModelServices.snapshot(settings, "reviewing", :reviewer, "fixture")
      started = DateTime.to_iso8601(DateTime.utc_now())

      File.write!(
        receipt,
        Jason.encode!(%{"status" => "reviewing", "recovery" => %{"started_at" => started, "agent_attempts" => 0, "events" => []}, "rounds" => [%{"evidence" => evidence, "usage" => %{}}]})
      )

      context = %{
        workspace: c.workspace,
        evidence: evidence,
        issue: c.issue,
        receipt: receipt,
        settings: settings,
        services: %{"reviewer" => service},
        models: %{reviewer: "gpt-test"},
        limit: 0,
        opts: []
      }

      assert {:error, {:model_call_failed, ^category}} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
      data = Receipt.read(receipt)
      assert data["recovery"]["agent_attempts"] == calls
      assert data["recovery"]["started_at"] == started
      assert Enum.all?(data["recovery"]["events"], &(&1["outcome"] != "passed"))

      for path <- Path.wildcard(Path.join(evidence, "agent-attempt-*/outcome.json")) do
        outcome = File.read!(path)
        assert outcome =~ Atom.to_string(category)
        refute outcome =~ "synthetic-route-reviewer"
      end
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp drain_events(acc) do
    receive do
      {:event, msg} -> drain_events([msg | acc])
    after
      0 -> acc
    end
  end

  defp write_server(path) do
    File.write!(path, ~S"""
    import sys, os, json, pathlib, hashlib, re
    trace, mode = sys.argv[1:]
    home = os.environ['CODEX_HOME']
    data = {'home': home, 'config': pathlib.Path(home, 'config.toml').read_text(),
            'credential_hash': hashlib.sha256(os.environ['SYMPHONY_MODEL_KEY'].encode()).hexdigest(),
            'base_url_environment': os.environ.get('OPENAI_BASE_URL'), 'requests': []}
    def write_trace(): pathlib.Path(trace).write_text(json.dumps(data))
    def send(obj): print(json.dumps(obj), flush=True)
    for line in sys.stdin:
        req = json.loads(line); data['requests'].append(req); write_trace()
        method, rid = req.get('method'), req.get('id')
        if method == 'initialize': send({'id': rid, 'result': {}})
        elif method == 'model/list':
            if mode == 'malformed': send({'id': rid, 'result': {'data': 'bad'}})
            else:
                cursor = req['params']['cursor']
                send({'id': rid, 'result': {'data': [{'model': 'gpt-test' if cursor is None else 'gpt-next',
                      'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}],
                      'nextCursor': 'page-two' if cursor is None or mode == 'cycle' else None}})
        elif method == 'environment/status': send({'id': rid, 'result': {'status': 'unknown'}})
        elif method == 'environment/info': send({'id': rid, 'result': {'cwd': 'file:///workspace'}})
        elif method == 'thread/start': send({'id': rid, 'result': {'thread': {'id': 'thread'}}})
        elif method == 'turn/start':
            send({'id': rid, 'result': {'turn': {'id': 'turn'}}})
            if mode == 'error':
                print('error ' + os.environ['SYMPHONY_MODEL_KEY'], file=sys.stderr, flush=True)
                send({'method': 'turn/failed', 'params': {'error': 'permission denied ' + os.environ['SYMPHONY_MODEL_KEY']}})
            else:
                text = '{"ok":true}' if mode == 'success' else '{"approved":true,"summary":"ok"}'
                if mode.startswith('probe'):
                    filename = re.search(r'model-capability-probe-[a-f0-9]+', req['params']['input'][0]['text']).group()
                    token = pathlib.Path(os.environ['GH12_PROBE_WORKSPACE'], filename).read_text()
                    send({'method': 'item/completed', 'params': {'item': {'type': 'commandExecution', 'exitCode': 0}}})
                    text = json.dumps({'token': token})
                send({'method': 'item/completed', 'params': {'item': {'type': 'agentMessage', 'text': text}}})
                status, error = 'completed', None
                terminal_mode = mode.removeprefix('probe-')
                if terminal_mode in ('401', '403', '429', '503', 'quota'):
                    status = 'failed'
                    info = 'usageLimitExceeded' if terminal_mode == 'quota' else {'httpConnectionFailed': {'httpStatusCode': int(terminal_mode)}}
                    error = {'message': 'failure ' + os.environ['SYMPHONY_MODEL_KEY'], 'codexErrorInfo': info, 'additionalDetails': None}
                elif terminal_mode == 'interrupted': status = 'interrupted'
                elif terminal_mode == 'malformed-turn': status = 'inProgress'
                elif terminal_mode in ('completed-error', 'legacy-error'):
                    error = {'message': 'denied', 'codexErrorInfo': {'httpConnectionFailed': {'httpStatusCode': 401}}}
                turn = {'id': 'turn', 'status': status, 'error': error}
                if terminal_mode == 'null-turn': turn = None
                elif terminal_mode == 'missing-status': turn = {'id': 'turn'}
                params = {'threadId': 'thread', 'turn': turn}
                if terminal_mode == 'bad-params': params = []
                elif terminal_mode == 'legacy-error': params = {'error': error}
                send({'method': 'turn/completed', 'params': params})
    """)
  end
end
