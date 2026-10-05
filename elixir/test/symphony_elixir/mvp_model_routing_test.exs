defmodule SymphonyElixir.MvpModelRoutingTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias Mix.Tasks.Mvp.Models
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

  test "configuration fallback cannot register a default account's catalog or pass a turn", c do
    for mode <- ~w(warning-before-init warning-after-init warning-details warning-page-two warning-turn warning-output malformed-warning malformed-warning-details) do
      trace = Path.join(c.root, "#{mode}.json")
      settings = %{c.settings | model_command: "python3 #{c.binary} #{trace} #{mode}", state_dir: Path.join(c.root, "state-#{mode}")}
      settings = put_in(settings.model_services["presets"]["coding"]["connection"]["base_url"], "https://unverified-channel.example/v1")
      {:ok, service} = ModelServices.snapshot(settings, "coding", :coder, "fixture")

      if mode in ~w(warning-turn warning-output) do
        assert {:error, :model_service_configuration_invalid} =
                 AppServer.run(c.workspace, "test", c.issue, model: service["model"], model_service: service)
      else
        assert {:error, :model_service_configuration_invalid} = AppServer.list_models(service)
        assert {:error, {:model_discovery_failed, failed}} = ModelCatalog.refresh(settings, "coding")
        previous = settings.model_services["catalog"]["coding"]
        assert failed["catalog"]["coding"] == Map.put(previous, "error", "discovery_failed")
        assert failed["validations"] == settings.model_services["validations"]
        refute failed["catalog"]["coding"]["models"]["gpt-next"]
        assert {:error, :model_discovery_failed} = Models.execute("refresh", settings, ["coding"])
        assert {:ok, saved} = ModelServices.load(ModelServices.path(settings), nil)
        assert saved["catalog"]["coding"] == failed["catalog"]["coding"]
        assert saved["validations"] == failed["validations"]
        requests = trace |> File.read!() |> Jason.decode!() |> Map.fetch!("requests")
        refute Enum.any?(requests, &(&1["method"] in ["thread/start", "turn/start"]))
      end
    end
  end

  test "real Codex loads both legacy auth-home roles and their frozen effort without inference", c do
    codex = System.get_env("SYMPHONY_TEST_CODEX") || System.find_executable("codex") || "/opt/codex"
    assert File.regular?(codex), "Codex client unavailable: #{codex}"
    home = Path.join(c.root, "client-auth")
    File.mkdir!(home)
    # The isolated legacy path only uses auth.json, even with incompatible home config.
    File.write!(Path.join(home, "config.toml"), ~s(profile = "ignored"\nmodel_reasoning_effort = "low"\n))
    settings = %{c.settings | model_services: nil, model_command: "env TOKIO_WORKER_THREADS=2 #{codex} app-server"}
    settings = Map.put(settings, :sandbox, %{:enabled => true, "auth_home" => home})
    assert {:ok, models} = Intake.resolve_comments([F.comment(1, "/symphony models reviewer=gpt-test")], settings)
    client_workflow(c.workspace)

    token = "e30." <> Base.url_encode64(Jason.encode!(%{"sub" => "offline", "exp" => 4_102_444_800}), padding: false) <> ".synthetic"

    auths = [
      {%{"OPENAI_API_KEY" => "synthetic-offline-client-key"}, "openai_base_url", "https://api.openai.com/v1"},
      {%{"tokens" => %{"id_token" => token, "access_token" => token, "refresh_token" => "synthetic-refresh"}}, "chatgpt_base_url", "https://chatgpt.com/backend-api"}
    ]

    for {auth, route_key, route} <- auths, role <- ~w(coder reviewer) do
      File.write!(Path.join(home, "auth.json"), Jason.encode!(auth))
      assert {:ok, services} = ModelServices.freeze(models, settings, environment: fn _ -> nil end)
      service = services[role]
      assert service["parameters"] == %{"reasoning_effort" => "high"}
      config = client_config(c.workspace, service)
      assert config["model_reasoning_effort"] == "high"
      assert config["model_provider"] == "openai"
      assert config[route_key] == route
    end
  end

  test "real Codex accepts independent registered API-key providers without inference", c do
    codex = System.get_env("SYMPHONY_TEST_CODEX") || System.find_executable("codex") || "/opt/codex"
    assert File.regular?(codex), "Codex client unavailable: #{codex}"
    settings = %{c.settings | model_command: "env TOKIO_WORKER_THREADS=2 #{codex} app-server"}
    client_workflow(c.workspace)

    for {role, id} <- [{:coder, "coding"}, {:reviewer, "reviewing"}] do
      {:ok, service} = ModelServices.snapshot(settings, id, role, "fixture")
      config = client_config(c.workspace, service)
      assert config["model_provider"] == "symphony"
      assert config["model_providers"]["symphony"]["base_url"] == service["connection"]["base_url"]
      assert config["model_providers"]["symphony"]["env_key"] == "SYMPHONY_MODEL_KEY"
      assert config["model_reasoning_effort"] == service["parameters"]["reasoning_effort"]
    end
  end

  test "legacy nonisolated native API routing freezes both roles and loads in real Codex", c do
    auth = %{"OPENAI_API_KEY" => "synthetic-native-api-key"}

    for effort <- ["low", nil] do
      assert_native_legacy_routing(c, auth, "openai_base_url", "https://native-api.example/v1", effort)
    end
  end

  test "legacy quoted project tables preserve both roles' routing without editing the original config", c do
    auth = %{"OPENAI_API_KEY" => "synthetic-native-api"}

    for table <- [~s([projects."/controlled/repo"]), "[projects.'/controlled/repo'] # project trust"] do
      assert_native_legacy_routing(c, auth, "openai_base_url", "https://native-api.example/v1", "low", table <> "\ntrust_level = 'trusted'\n")
    end
  end

  test "legacy config flags freeze effective effort through later defaults and repeated role calls", c do
    home = Path.join(c.root, "command-home")
    File.mkdir!(home)
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"OPENAI_API_KEY" => "synthetic-command-auth"}))
    codex = System.get_env("SYMPHONY_TEST_CODEX") || System.find_executable("codex") || "/opt/codex"
    client_workflow(c.workspace)

    for suffix <- [
          "--config model_reasoning_effort=xhigh",
          ~s(-c 'model_reasoning_effort="xhigh"'),
          "--config=model_reasoning_effort=xhigh",
          "-c=model_reasoning_effort=xhigh",
          "-cmodel_reasoning_effort=xhigh",
          "-c model_reasoning_effort=low --config model_reasoning_effort=xhigh"
        ] do
      File.write!(Path.join(home, "config.toml"), ~s(model_reasoning_effort = "low"\n))
      settings = %{c.settings | model_services: nil, model_command: "env TOKIO_WORKER_THREADS=2 #{codex} #{suffix} app-server"}
      settings = Map.put(settings, :sandbox, %{"auth_home" => home})
      assert {:ok, models} = Intake.resolve_comments([F.comment(1, "/symphony models reviewer=gpt-test")], settings)
      assert {:ok, services} = ModelServices.freeze(models, settings, environment: fn _ -> nil end)
      changed = %{settings | model_command: "codex -c model_reasoning_effort=high app-server"}
      File.write!(Path.join(home, "config.toml"), ~s(model_reasoning_effort = "medium"\n))

      for role <- [:coder, :reviewer] do
        service = services[Atom.to_string(role)]
        assert service["command"] == settings.model_command
        assert service["parameters"] == %{"reasoning_effort" => "xhigh"}
        assert client_config(c.workspace, service)["model_reasoning_effort"] == "xhigh"
        context = %{models: models, services: services, settings: changed}
        assert {:ok, options} = ModelServices.options(context, role)
        assert options[:model_service] == service
        trace = Path.join(home, "#{role}.json")
        command = "python3 #{c.binary} #{trace} success #{suffix}"
        simulated = Map.put(service, "command", command)

        for _attempt <- 1..2 do
          assert {:ok, _} = ModelServices.run(c.workspace, "test", c.issue, model: service["model"], model_service: simulated, read_only: role == :reviewer)
          data = trace |> File.read!() |> Jason.decode!()
          assert data["config"] =~ ~s(model_reasoning_effort = "xhigh")
          assert data["config"] =~ ~s(openai_base_url = "https://api.openai.com/v1")
          assert data["credential_hash"] == hash(File.read!(Path.join(home, "auth.json")))
          turn = Enum.find(data["requests"], &(&1["method"] == "turn/start"))["params"]
          assert turn["model"] == service["model"]
          assert turn["effort"] == "xhigh"
          if role == :reviewer, do: assert(turn["sandboxPolicy"] == %{"type" => "readOnly"})
        end

        mismatch = put_in(service["parameters"]["reasoning_effort"], "high")
        invalid_options = [model: service["model"], model_service: mismatch]
        assert {:error, :invalid_model_service_snapshot} = AppServer.start_session(c.workspace, invalid_options)
        registered = %{c.settings | model_command: settings.model_command}
        assert {:error, :model_service_command_unsafe} = ModelServices.snapshot(registered, "coding", role, "fixture")
      end
    end
  end

  test "legacy nonisolated native ChatGPT roots freeze the exact Codex suffix for both roles", c do
    token = "e30." <> Base.url_encode64(Jason.encode!(%{"sub" => "offline", "exp" => 4_102_444_800}), padding: false) <> ".synthetic"
    auth = %{"tokens" => %{"id_token" => token, "access_token" => token, "refresh_token" => "synthetic-refresh"}}

    for root <- ["https://native-chatgpt.example/backend-api", "https://native-chatgpt.example/backend-api/", "https://native-chatgpt.example/backend-api/codex"] do
      assert_native_legacy_routing(c, auth, "chatgpt_base_url", root, nil)
    end

    assert_native_legacy_routing(c, auth, "chatgpt_base_url", "https://native-chatgpt.example/backend-api", "medium")
  end

  test "legacy native fields respect authentication and provider precedence and reject malformed routes", c do
    home = Path.join(c.root, "native-precedence")
    File.mkdir!(home)
    settings = %{c.settings | model_services: nil} |> Map.put(:sandbox, %{"auth_home" => home})
    models = %{coder: "gpt-test", reviewer: "gpt-test"}
    native = ~s(openai_base_url = "https://native-api.example/v1"\nchatgpt_base_url = "https://native-chatgpt.example/backend-api"\n)

    environment = fn
      "OPENAI_BASE_URL" -> "https://environment.example/v1"
      "OPENAI_API_KEY" -> "synthetic-environment-key"
      _ -> nil
    end

    File.write!(Path.join(home, "config.toml"), native)
    assert {:ok, services} = ModelServices.freeze(models, settings, environment: environment)
    assert services["coder"]["credential_ref"] == "env:OPENAI_API_KEY"
    assert services["coder"]["connection"]["base_url"] == "https://native-api.example/v1"

    custom = ~s(model_provider = "company"\n[model_providers.company]\nbase_url = "https://custom.example/v1"\nenv_key = "GH12_CODER_KEY"\n)
    File.write!(Path.join(home, "config.toml"), native <> custom)
    assert {:ok, services} = ModelServices.freeze(models, settings, environment: environment)
    assert services["reviewer"]["credential_ref"] == "env:GH12_CODER_KEY"
    assert services["reviewer"]["connection"]["base_url"] == "https://custom.example/v1"

    for field <- ~w(openai_base_url chatgpt_base_url), value <- ["true", "12", ~s("http://unsafe.example"), ~s("https://user:secret@unsafe.example"), ~s("https://unsafe.example?secret=value")] do
      auth = if field == "chatgpt_base_url", do: %{"tokens" => %{"access_token" => "synthetic"}}, else: %{"OPENAI_API_KEY" => "synthetic"}
      File.write!(Path.join(home, "auth.json"), Jason.encode!(auth))
      File.write!(Path.join(home, "config.toml"), "#{field} = #{value}\n")
      assert {:error, :legacy_model_service_migration_required} = ModelServices.freeze(models, settings, environment: fn _ -> nil end)
    end
  end

  test "local catalog discovery uses AppServer and refuses inference without the kernel sandbox", c do
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

  test "legacy isolated claims ignore auth home configuration and freeze the generated baseline routing", c do
    home = Path.join(c.root, "isolated-legacy-home")
    File.mkdir!(home)
    auth = Jason.encode!(%{"OPENAI_API_KEY" => "synthetic-legacy-auth"})
    File.write!(Path.join(home, "auth.json"), auth)
    settings = c.settings |> Map.put(:model_services, nil) |> Map.put(:sandbox, %{:enabled => true, "auth_home" => home})
    assert {:ok, models} = Intake.resolve_comments([F.comment(1, "/symphony models reviewer=gpt-test")], settings)

    for raw <- [
          ~s(model_reasoning_effort = "low"\n),
          ~s(model_provider = "company"\n[model_providers.company]\nbase_url = "https://ignored.example/v1"\nenv_key = "GH12_CODER_KEY"\n),
          ~s(profile = "production"\n[profiles.production]\nmodel_reasoning_effort = "low"\n)
        ] do
      File.write!(Path.join(home, "config.toml"), raw)
      assert {:ok, services} = ModelServices.freeze(models, settings, environment: fn _ -> nil end)
      # Even unreadable or malformed later config cannot alter the frozen services.
      File.write!(Path.join(home, "config.toml"), "not valid TOML")

      for role <- ~w(coder reviewer) do
        service = services[role]
        assert service["parameters"] == %{"reasoning_effort" => "high"}
        assert service["connection"] == %{"base_url" => "https://api.openai.com/v1", "protocol" => "responses"}
        assert service["credential_ref"] == "auth_home:" <> home
        assert service["source"] == "legacy_migration"
        assert is_nil(service["capability_evidence"])
        trace = Path.join(c.root, "isolated-legacy-#{role}.json")
        service = Map.put(service, "command", "python3 #{c.binary} #{trace} success")
        assert {:ok, _} = ModelServices.run(c.workspace, "test", c.issue, model: models[String.to_existing_atom(role)], model_service: service, read_only: role == "reviewer")
        data = trace |> File.read!() |> Jason.decode!()
        assert data["config"] =~ ~s(model_provider = "openai")
        assert data["config"] =~ "https://api.openai.com/v1"
        refute data["config"] =~ "ignored.example"
        assert data["credential_hash"] == hash(auth)
        assert data["credential_hash"] != hash("synthetic-route-coder")
        turn = Enum.find(data["requests"], &(&1["method"] == "turn/start"))
        assert turn["params"]["effort"] == "high"
        assert turn["params"]["model"] == service["model"]
      end
    end
  end

  test "unsupported model confirmation fields remain unknown through repeated turns and persisted requests", c do
    alias SymphonyElixir.Mvp.{Receipt, Usage}
    trace = Path.join(c.root, "telemetry.json")
    {:ok, service} = ModelServices.snapshot(c.settings, "coding", :coder, "fixture")
    service = Map.put(service, "command", "python3 #{c.binary} #{trace} telemetry")
    receipt = Path.join(c.root, "telemetry-receipt.json")
    File.write!(receipt, Jason.encode!(%{"status" => "coding", "services" => %{"coder" => service}, "rounds" => [%{"usage" => %{}}]}))
    assert {:ok, session} = AppServer.start_session(c.workspace, model: "gpt-test", model_service: service, tools: false)

    try do
      for index <- 1..3 do
        assert {:ok, result} = AppServer.run_turn(session, "test", c.issue)
        assert is_nil(result.actual_model)
        Usage.request(receipt, "coder_#{index}", service, result.actual_model)
        Usage.record(receipt, "coder_#{index}", result)
        round = List.last(Receipt.read(receipt)["rounds"])
        request = round["model_requests"]["coder_#{index}"]
        assert request == Map.take(service, ~w(id version provider model credential_ref source)) |> Map.put("actual_model", nil)
        assert round["usage"]["coder_#{index}"] == Usage.empty()
      end
    after
      AppServer.stop_session(session)
    end

    requests = trace |> File.read!() |> Jason.decode!() |> Map.fetch!("requests")
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 1
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 3
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
          {"unauthorized", :model_account_forbidden},
          {"usageLimitExceeded", :model_quota_exhausted},
          {"rateLimitExceeded", :model_rate_limited},
          {"serverOverloaded", :model_service_unavailable},
          {"internalServerError", :model_service_unavailable},
          {"badRequest", :unclassified},
          {"other", :unclassified},
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
        :unclassified -> assert {:error, {:turn_failed, %{"codexErrorInfo" => ^mode}}} = result
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

    cases = [
      {"401", :model_account_forbidden, 1},
      {"quota", :model_quota_exhausted, 1},
      {"unauthorized", :model_account_forbidden, 1},
      {"usageLimitExceeded", :model_quota_exhausted, 1},
      {"rateLimitExceeded", :model_rate_limited, 2},
      {"serverOverloaded", :model_service_unavailable, 2},
      {"internalServerError", :model_service_unavailable, 2},
      {"badRequest", :unclassified, 1},
      {"other", :unclassified, 1},
      {"429", :model_rate_limited, 2},
      {"503", :model_service_unavailable, 2},
      {"warning-output", :configuration_invalid, 1}
    ]

    budgets = [{"stage", 2, 4}, {"total", 4, 2}, {"wall", 4, 4}]

    for {mode, category, calls} <- cases, {budget, stage, total} <- budgets do
      receipt = Path.join(c.root, "attempts-#{mode}-#{budget}.json")
      evidence = receipt <> ".evidence"
      File.mkdir_p!(evidence)
      settings = %{c.settings | model_command: "python3 #{c.binary} #{c.root}/attempt-#{mode}.json #{mode}"}
      {:ok, recovery} = Recovery.settings(%{"enabled" => true, "stage_attempts" => stage, "max_agent_attempts" => total, "max_elapsed_ms" => 10_000})
      settings = Map.put(settings, :recovery, recovery)
      # The execution command is part of the binding; independently authorize this fixture.
      {:ok, service} = ModelServices.snapshot(settings, "reviewing", :reviewer, "fixture")
      {:ok, registry} = ModelCatalog.attest(settings.model_services, service, F.proof(:reviewer))
      settings = %{settings | model_services: registry}
      F.write_authority!(settings)
      {:ok, service} = ModelServices.snapshot(settings, "reviewing", :reviewer, "fixture")
      started = DateTime.to_iso8601(DateTime.utc_now())
      {:ok, start_time, _} = DateTime.from_iso8601(started)
      clock = :atomics.new(1, [])
      :atomics.put(clock, 1, DateTime.to_unix(start_time, :millisecond))
      parent = self()

      agent = fn workspace, prompt, issue, options ->
        send(parent, {:attempt_options, options})
        result = ModelServices.run(workspace, prompt, issue, options)
        :atomics.add(clock, 1, if(budget == "wall", do: 10_000, else: 100))
        result
      end

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
        opts: [agent: agent, now_ms: fn -> :atomics.get(clock, 1) end]
      }

      failure =
        case category do
          :unclassified -> {:turn_failed, %{"codexErrorInfo" => mode, "message" => "protocol failure"}}
          :configuration_invalid -> :model_service_configuration_invalid
          _ -> {:model_call_failed, category}
        end

      expected = if budget == "wall" or (budget == "total" and calls == 2), do: :mvp_recovery_resource_exhausted, else: failure
      assert {:error, ^expected} = Attempts.run(context, :reviewer, "review", fn -> :ok end)
      data = Receipt.read(receipt)
      assert data["recovery"]["agent_attempts"] == if(budget == "wall", do: 1, else: calls)
      assert data["recovery"]["started_at"] == started
      assert Enum.all?(data["recovery"]["events"], &(&1["outcome"] != "passed"))
      assert_receive {:attempt_options, first_options}
      assert first_options[:wall_timeout_ms] == 10_000
      assert first_options[:model_service] == service
      assert first_options[:read_only]

      if calls == 2 and budget != "wall" do
        assert_receive {:attempt_options, next_options}
        assert next_options[:wall_timeout_ms] == 9900
        assert next_options[:model_service] == service
      end

      refute_receive {:attempt_options, _}, 0

      for path <- Path.wildcard(Path.join(evidence, "agent-attempt-*/outcome.json")) do
        outcome = File.read!(path)
        assert outcome =~ if(category == :unclassified, do: mode, else: Atom.to_string(category))
        refute outcome =~ "synthetic-route-reviewer"
      end
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp assert_native_legacy_routing(c, auth, field, route, effort, extra_config \\ "") do
    home = Path.join(c.root, "native-home-#{System.unique_integer([:positive])}")
    File.mkdir!(home)
    auth_json = Jason.encode!(auth)
    File.write!(Path.join(home, "auth.json"), auth_json)
    parameters = if effort, do: %{"reasoning_effort" => effort}, else: %{}
    effort_config = if effort, do: ~s(model_reasoning_effort = "#{effort}"\n), else: ""
    original_config = ~s(#{field} = "#{route}"\n) <> effort_config <> extra_config
    File.write!(Path.join(home, "config.toml"), original_config)
    previous_home = System.get_env("CODEX_HOME")
    System.put_env("CODEX_HOME", home)
    on_exit(fn -> restore_env("CODEX_HOME", previous_home) end)
    codex = System.get_env("SYMPHONY_TEST_CODEX") || System.find_executable("codex") || "/opt/codex"
    assert File.regular?(codex), "Codex client unavailable: #{codex}"
    settings = %{c.settings | model_services: nil, model_command: "env TOKIO_WORKER_THREADS=2 #{codex} app-server"}
    assert {:ok, models} = Intake.resolve_comments([F.comment(1, "/symphony models reviewer=gpt-test")], settings)
    # The native root field wins over OPENAI_BASE_URL; neither can replace ChatGPT's root.
    environment = fn name -> if name == "OPENAI_BASE_URL", do: "https://environment-wrong.example/v1" end
    assert {:ok, services} = ModelServices.freeze(models, settings, environment: environment)
    assert File.read!(Path.join(home, "config.toml")) == original_config
    File.write!(Path.join(home, "config.toml"), ~s(#{field} = "https://changed-wrong.example/v1"\nmodel_reasoning_effort = "high"\n))
    effective_route = if field == "chatgpt_base_url", do: String.trim_trailing(route, "/") <> "/codex", else: route
    client_workflow(c.workspace)

    for role <- ~w(coder reviewer) do
      service = services[role]
      assert service["connection"] == %{"base_url" => effective_route, "protocol" => "responses"}
      assert service["parameters"] == parameters
      assert service["credential_ref"] == "auth_home:" <> home
      assert service["credential_identity"] == hash(auth_json)
      assert service["source"] == "legacy_migration"
      assert service["model"] == models[String.to_existing_atom(role)]
      assert :ok = ModelServices.connection_ready(service)
      config = client_config(c.workspace, service)
      assert config["model_provider"] == "openai"
      assert config[field] == String.trim_trailing(route, "/")
      assert config["model_reasoning_effort"] == effort
      trace = Path.join(home, "#{role}.json")
      simulated = Map.put(service, "command", "python3 #{c.binary} #{trace} success")
      assert {:ok, _} = ModelServices.run(c.workspace, "test", c.issue, model: service["model"], model_service: simulated, read_only: role == "reviewer")
      data = trace |> File.read!() |> Jason.decode!()
      assert data["credential_hash"] == hash(auth_json)
      assert data["config"] =~ ~s(#{field} = "#{String.trim_trailing(route, "/")}")
      refute data["config"] =~ "changed-wrong"
      refute data["config"] =~ "environment-wrong"
      turn = Enum.find(data["requests"], &(&1["method"] == "turn/start"))["params"]
      assert turn["model"] == service["model"]
      assert turn["effort"] == effort
    end

    restore_env("CODEX_HOME", previous_home)
  end

  defp client_workflow(workspace) do
    root = Path.dirname(workspace)
    opts = [workspace_root: root, codex_read_timeout_ms: 5000, codex_approval_policy: "never"]
    write_workflow_file!(Workflow.workflow_file_path(), opts)
  end

  defp client_config(workspace, service) do
    read_only = service["role"] == "reviewer"
    opts = [model: service["model"], model_service: service, tools: false, read_only: read_only]
    assert {:ok, session} = AppServer.start_session(workspace, opts)

    try do
      refute File.read!(Path.join(session.service_runtime.home, "config.toml")) =~ "[model_providers.openai]"
      Port.command(session.port, Jason.encode!(%{"id" => 90, "method" => "config/read", "params" => %{}}) <> "\n")
      client_response(session.port, 90)["config"]
    after
      # Wait for this native test client to exit before deleting its writer home.
      try do
        {:os_pid, pid} = Port.info(session.port, :os_pid)
        assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        port = session.port
        assert_receive {^port, {:exit_status, _}}, 5000
      after
        AppServer.stop_session(session)
      end

      refute File.exists?(session.service_runtime.home)
    end
  end

  defp client_response(port, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(to_string(line)) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            result

          {:ok, %{"id" => ^id, "error" => error}} ->
            flunk("Codex request failed: #{inspect(error)}")

          {:ok, %{"method" => "configWarning", "params" => %{"summary" => summary}}} ->
            refute summary =~ "Invalid configuration"
            client_response(port, id)

          _ ->
            client_response(port, id)
        end

      {^port, {:exit_status, status}} ->
        flunk("Codex exited: #{status}")
    after
      5000 -> flunk("Codex config/read timed out")
    end
  end

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
    trace, mode = sys.argv[1:3]
    home = os.environ['CODEX_HOME']
    credential = os.environ.get('SYMPHONY_MODEL_KEY')
    credential = credential.encode() if credential else pathlib.Path(home, 'auth.json').read_bytes()
    data = {'home': home, 'config': pathlib.Path(home, 'config.toml').read_text(),
            'credential_hash': hashlib.sha256(credential).hexdigest(),
            'base_url_environment': os.environ.get('OPENAI_BASE_URL'), 'requests': []}
    turns = 0
    def write_trace(): pathlib.Path(trace).write_text(json.dumps(data))
    def send(obj): print(json.dumps(obj), flush=True)
    def warning():
        send({'method': 'configWarning', 'params': {'summary': 'Invalid configuration; using defaults.',
              'details': 'Rejected managed configuration'}})
    for line in sys.stdin:
        req = json.loads(line); data['requests'].append(req); write_trace()
        method, rid = req.get('method'), req.get('id')
        if method == 'initialize':
            send({'method': 'configWarning', 'params': {'summary': 'Linux sandbox needs user namespaces.', 'details': None}})
            if mode == 'warning-before-init': warning()
            send({'id': rid, 'result': {}})
            if mode == 'warning-after-init': warning()
            if mode == 'warning-details':
                send({'method': 'configWarning', 'params': {'summary': 'Configuration warning',
                      'details': 'Falling back to defaults'}})
            if mode == 'malformed-warning': send({'method': 'configWarning', 'params': []})
            if mode == 'malformed-warning-details':
                send({'method': 'configWarning', 'params': {'summary': 'Configuration warning', 'details': {}}})
        elif method == 'model/list':
            if mode == 'malformed': send({'id': rid, 'result': {'data': 'bad'}})
            else:
                cursor = req['params']['cursor']
                if mode == 'warning-page-two' and cursor is not None: warning()
                send({'id': rid, 'result': {'data': [{'model': 'gpt-test' if cursor is None else 'gpt-next',
                      'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}],
                      'nextCursor': 'page-two' if cursor is None or mode == 'cycle' else None}})
        elif method == 'environment/status': send({'id': rid, 'result': {'status': 'unknown'}})
        elif method == 'environment/info': send({'id': rid, 'result': {'cwd': 'file:///workspace'}})
        elif method == 'thread/start': send({'id': rid, 'result': {'thread': {'id': 'thread', 'model': 'gpt-configured'}}})
        elif method == 'turn/start':
            turns += 1
            if mode == 'warning-turn': warning()
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
                if mode == 'warning-output': warning()
                status, error = 'completed', None
                terminal_mode = mode.removeprefix('probe-')
                if terminal_mode in ('401', '403', '429', '503', 'quota'):
                    status = 'failed'
                    info = 'usageLimitExceeded' if terminal_mode == 'quota' else {'httpConnectionFailed': {'httpStatusCode': int(terminal_mode)}}
                    error = {'message': 'failure ' + os.environ['SYMPHONY_MODEL_KEY'], 'codexErrorInfo': info, 'additionalDetails': None}
                elif terminal_mode in ('unauthorized', 'usageLimitExceeded', 'rateLimitExceeded', 'serverOverloaded', 'internalServerError', 'badRequest', 'other'):
                    status = 'failed'
                    error = {'message': 'protocol failure', 'codexErrorInfo': terminal_mode}
                elif terminal_mode == 'interrupted': status = 'interrupted'
                elif terminal_mode == 'malformed-turn': status = 'inProgress'
                elif terminal_mode in ('completed-error', 'legacy-error'):
                    error = {'message': 'denied', 'codexErrorInfo': {'httpConnectionFailed': {'httpStatusCode': 401}}}
                turn = {'id': 'turn', 'status': status, 'error': error}
                if terminal_mode == 'null-turn': turn = None
                elif terminal_mode == 'missing-status': turn = {'id': 'turn'}
                params = {'threadId': 'thread', 'turn': turn}
                if mode == 'telemetry' and turns == 1: params['actualModel'] = 'gpt-unconfirmed'
                elif mode == 'telemetry' and turns == 2: params['actualModel'] = {'invalid': 'gpt-invalid'}
                if terminal_mode == 'bad-params': params = []
                elif terminal_mode == 'legacy-error': params = {'error': error}
                send({'method': 'turn/completed', 'params': params})
    """)
  end
end
