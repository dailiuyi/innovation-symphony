defmodule SymphonyElixir.MvpModelRoutingTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp.ModelServices

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
            'credential_hash': hashlib.sha256(os.environ['SYMPHONY_MODEL_KEY'].encode()).hexdigest(), 'requests': []}
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
        elif method == 'thread/start': send({'id': rid, 'result': {'thread': {'id': 'thread'}}})
        elif method == 'turn/start':
            send({'id': rid, 'result': {'turn': {'id': 'turn'}}})
            if mode == 'error':
                print('error ' + os.environ['SYMPHONY_MODEL_KEY'], file=sys.stderr, flush=True)
                send({'method': 'turn/failed', 'params': {'error': 'permission denied ' + os.environ['SYMPHONY_MODEL_KEY']}})
            else:
                text = '{"ok":true}'
                if mode == 'probe':
                    filename = re.search(r'model-capability-probe-[a-f0-9]+', req['params']['input'][0]['text']).group()
                    token = pathlib.Path(req['params']['cwd'], filename).read_text()
                    send({'method': 'item/completed', 'params': {'item': {'type': 'commandExecution', 'exitCode': 0}}})
                    text = json.dumps({'token': token})
                send({'method': 'item/completed', 'params': {'item': {'type': 'agentMessage', 'text': text}}})
                send({'method': 'turn/completed', 'params': {}})
    """)
  end
end
