defmodule SymphonyElixir.MvpModelSettingsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp.{DeepSeek, Intake, ModelCatalog, ModelServices, ModelSettings, ModelSettingsServer}

  setup do
    root = Path.join(System.tmp_dir!(), "gh16-#{System.unique_integer([:positive])}")
    System.put_env("GH12_CODER_KEY", "synthetic-settings-coder")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-settings-reviewer")
    System.put_env("GH16_ADMIN", String.duplicate("a", 40))

    repos =
      Map.new(["a", "b"], fn id ->
        s = F.settings(Path.join(root, id))
        {:ok, wf} = Workflow.load(s.workflow_path)
        config = put_in(wf.config, ["tracker", "provider"], %{"repo" => "owner/" <> id})
        File.write!(s.workflow_path, "---\n" <> Jason.encode!(config) <> "\n---\nfixture")
        {id, %{"repository" => "owner/" <> id, "workflow" => s.workflow_path, "state_dir" => s.state_dir}}
      end)

    config = %{"origin" => "http://127.0.0.1:8613", "port" => 0, "token_ref" => "env:GH16_ADMIN", "repositories" => repos}
    path = Path.join(root, "manager.json")
    File.write!(path, Jason.encode!(config))

    on_exit(fn ->
      for env <- ~w(GH12_CODER_KEY GH12_REVIEWER_KEY GH16_ADMIN), do: System.delete_env(env)
      File.rm_rf!(root)
    end)

    %{root: root, config: config, path: path}
  end

  test "two repositories and roles persist independently, CAS retains values and tasks remain frozen", c do
    {:ok, s} = ModelSettings.settings(c.config, "a")
    {:ok, before} = Intake.resolve_comments([], s)
    {:ok, service} = ModelServices.snapshot(s, "reviewing", :coder, "test")
    {:ok, registry} = ModelCatalog.attest(s.model_services, service, F.proof(:coder))
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 0, registry)
    {:ok, shown} = ModelSettings.show(c.config, "a")
    selected = Enum.find(shown["roles"]["coder"], &(&1["selection"]["preset"] == "reviewing" and &1["selection"]["parameters"]["reasoning_effort"] == "high"))
    assert selected["state"] == "available"
    request = %{"workflow_version" => shown["workflow_version"], "revision" => 1, "defaults" => Map.put(shown["defaults"], "coder", selected["selection"])}
    assert {:ok, next} = ModelSettings.save(c.config, "a", request)
    assert next["revision"] == 2
    assert next["effective_defaults"]["coder"] == selected["selection"]
    assert next["defaults"]["reviewer"] == shown["defaults"]["reviewer"]
    assert {:ok, ^next} = ModelSettings.show(c.config, "a")
    {:ok, other} = ModelSettings.show(c.config, "b")
    assert other["revision"] == 0
    assert other["defaults"]["coder"] == "coding"
    {:ok, updated} = ModelSettings.settings(c.config, "a")
    {:ok, claimed} = Intake.resolve_comments([], updated)
    assert claimed.services["coder"]["parameters"] == %{"reasoning_effort" => "high"}
    {:ok, override} = Intake.resolve_comments([F.comment(1, "/symphony models coder=gpt-test")], updated)
    assert override.services["coder"]["parameters"] == claimed.services["coder"]["parameters"]
    {:ok, reset} = Intake.resolve_comments([F.comment(1, "/symphony configs coder=coding"), F.comment(2, "/symphony configs coder=default")], updated)
    assert reset.coder == claimed.coder
    assert {:ok, opts} = ModelServices.options(%{settings: s, services: before.services}, :coder)
    assert opts[:model_service] == before.services["coder"]
    assert {:error, :model_services_conflict} = ModelSettings.save(c.config, "a", request)
    bad = put_in(request, ["defaults", "coder", "parameters", "reasoning_effort"], "none")
    assert {:error, :model_reasoning_effort_unsupported} = ModelSettings.save(c.config, "a", %{bad | "revision" => 2})
    assert {:ok, ^next} = ModelSettings.show(c.config, "a")
    revoked = Map.put(updated.model_services, "disabled_models", ["gpt-test"])
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), updated.model_services, 2, revoked)
    assert {:error, :model_disabled} = ModelServices.options(%{settings: s, services: before.services}, :diagnosis)
  end

  test "strict malformed input and repository binding refuse writes", c do
    assert :ok = ModelSettings.validate(c.config)
    assert {:ok, _} = ModelSettings.load(c.path)

    for config <- [
          nil,
          [],
          %{},
          Map.put(c.config, "secret", "no"),
          put_in(c.config, ["origin"], []),
          put_in(c.config, ["origin"], "http://user:pass@host/path"),
          put_in(c.config, ["repositories"], []),
          put_in(c.config, ["repositories", "a"], []),
          put_in(c.config, ["repositories", "a"], %{}),
          put_in(c.config, ["repositories", "a", "workflow"], "relative"),
          put_in(c.config, ["repositories", "a", "repository"], "no"),
          put_in(c.config, ["repositories", "b"], c.config["repositories"]["a"])
        ] do
      assert {:error, :invalid_model_settings_config} = ModelSettings.validate(config)
    end

    for path <- [c.root, "/missing"], do: assert({:error, :invalid_model_settings_config} = ModelSettings.load(path))
    File.write!(c.path, "{")
    assert {:error, :invalid_model_settings_config} = ModelSettings.load(c.path)

    for request <- [
          nil,
          [],
          %{},
          %{"defaults" => %{}, "revision" => -1},
          %{"defaults" => %{}, "revision" => "0"},
          %{"defaults" => %{}, "revision" => 0},
          %{"defaults" => %{}, "revision" => 0, "key" => "no"}
        ] do
      assert {:error, _} = ModelSettings.save(c.config, "a", request)
    end

    assert {:error, :model_settings_repository_unavailable} = ModelSettings.show(c.config, "unknown")
    assert {:error, :model_settings_repository_unavailable} = ModelSettings.show(put_in(c.config, ["repositories", "a", "repository"], "owner/wrong"), "a")
    assert {:error, :model_settings_repository_unavailable} = ModelSettings.show(put_in(c.config, ["repositories", "a", "state_dir"], c.root), "a")
    refute File.exists?(Path.join(c.config["repositories"]["a"]["state_dir"], "model-services.json"))
    workflow = c.config["repositories"]["a"]["workflow"]

    for tracker <- [nil, [], "malformed", %{"provider" => "malformed"}, %{"provider" => [%{}]}] do
      File.write!(workflow, "---\n" <> Jason.encode!(%{"tracker" => tracker}) <> "\n---\nfixture")
      assert {:error, :model_settings_repository_unavailable} = ModelSettings.show(c.config, "a")
    end
  end

  test "all four repository role selections persist without changing any other configuration", c do
    saved = save_four_defaults!(c.config)

    for id <- ["a", "b"] do
      assert {:ok, shown} = ModelSettings.show(c.config, id)
      assert shown == saved[id]
      assert shown["revision"] == 3
    end
  end

  @tag timeout: 120_000
  test "settings preserve and save verified legacy null presets without inventing depth evidence", c do
    for {id, efforts} <- [{"a", []}, {"b", ~w(medium high)}] do
      repo = c.config["repositories"][id]
      s = F.settings(repo["state_dir"], %{"reasoning_effort" => nil})

      registry =
        Enum.reduce(~w(coding reviewing), s.model_services, fn preset, registry ->
          {:ok, registry} = ModelCatalog.register(registry, preset, "gpt-test", efforts)
          registry
        end)

      registry =
        Enum.reduce([{:coder, "reviewing"}, {:reviewer, "coding"}], registry, fn {role, preset}, registry ->
          {:ok, service} = ModelServices.snapshot(%{s | model_services: registry}, preset, role, "fixture")
          {:ok, registry} = ModelCatalog.attest(registry, service, F.proof(role))
          registry
        end)

      {:ok, wf} = Workflow.load(s.workflow_path)
      config = wf.config |> put_in(["tracker", "provider"], %{"repo" => repo["repository"]}) |> put_in(["mvp", "model_services"], registry)
      File.write!(s.workflow_path, "---\n" <> Jason.encode!(config) <> "\n---\nfixture")
    end

    for id <- ~w(a b), {role, preset} <- [{"coder", "reviewing"}, {"reviewer", "coding"}] do
      {:ok, shown} = ModelSettings.show(c.config, id)
      other_id = if id == "a", do: "b", else: "a"
      {:ok, other_repo} = ModelSettings.show(c.config, other_id)
      other_role = if role == "coder", do: "reviewer", else: "coder"
      {:ok, s} = ModelSettings.settings(c.config, id)
      invariant = Map.drop(s.model_services, ~w(defaults revision))
      current = Enum.find(shown["roles"][role], &(&1["selection"] == shown["effective_defaults"][role]))
      assert current["state"] == "available"
      selection = %{"preset" => preset, "model" => "gpt-test", "parameters" => %{"reasoning_effort" => nil}}
      selected = Enum.find(shown["roles"][role], &(&1["selection"] == selection))
      assert selected["state"] == "available"
      assert selected["default_value"] == preset
      assert Enum.all?(shown["roles"][role], &(&1["state"] != "available" or &1["selection"]["parameters"] == %{"reasoning_effort" => nil}))
      request = %{"defaults" => Map.put(shown["defaults"], role, selected["default_value"]), "revision" => shown["revision"], "workflow_version" => shown["workflow_version"]}
      assert {:ok, saved} = ModelSettings.save(c.config, id, request)
      assert saved["defaults"][role] == preset
      assert saved["effective_defaults"][role] == selection
      assert saved["defaults"][other_role] == shown["defaults"][other_role]
      assert {:ok, ^other_repo} = ModelSettings.show(c.config, other_id)
      {:ok, persisted} = ModelServices.load(ModelServices.path(s), nil)
      assert Map.drop(persisted, ~w(defaults revision)) == invariant
      assert {:ok, reloaded_config} = ModelSettings.load(c.path)
      assert {:ok, ^saved} = ModelSettings.show(reloaded_config, id)
      assert {:error, :model_services_conflict} = ModelSettings.save(c.config, id, request)
      invalid = %{request | "revision" => saved["revision"], "defaults" => Map.put(saved["defaults"], role, selection)}
      assert {:error, :invalid_model_services} = ModelSettings.save(c.config, id, invalid)
      assert {:ok, ^saved} = ModelSettings.show(c.config, id)
    end

    saved =
      Map.new(~w(a b), fn id ->
        {:ok, shown} = ModelSettings.show(c.config, id)
        {id, shown}
      end)

    assert_packaged_restarts!(c, saved)
  end

  test "administrator entrypoint binds loopback; HTTP auth, origin, input and scope protection", c do
    assert ModelSettingsServer.init(c.path) == c.path
    assert {:ok, pid} = CLI.model_settings_start(c.path)
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    assert {:ok, %{status: 401}} = Req.get("http://127.0.0.1:#{port}/repositories", retry: false)
    GenServer.stop(pid)
    assert {:error, _} = CLI.model_settings_start("/missing")

    for {method, path, body, auth, origin, expected} <- [
          {"GET", "/repositories", "", nil, nil, 401},
          {"GET", "/repositories", "", "bad", nil, 401},
          {"GET", "/repositories", "", String.duplicate("a", 40), nil, 200},
          {"GET", "/repositories/a", "", String.duplicate("a", 40), nil, 200},
          {"GET", "/repositories/unknown", "", String.duplicate("a", 40), nil, 422},
          {"DELETE", "/repositories/a", "", String.duplicate("a", 40), nil, 404},
          {"POST", "/repositories/a", "{}", String.duplicate("a", 40), "http://evil", 403},
          {"POST", "/repositories/a", "{", String.duplicate("a", 40), c.config["origin"], 403},
          {"POST", "/repositories/a", "[]", String.duplicate("a", 40), c.config["origin"], 422},
          {"POST", "/repositories/a", String.duplicate("x", 20_000), String.duplicate("a", 40), c.config["origin"], 403}
        ] do
      conn = Plug.Test.conn(method, path, body)
      conn = if auth, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> auth), else: conn
      conn = if origin, do: conn |> Plug.Conn.put_req_header("origin", origin) |> Plug.Conn.put_req_header("content-type", "application/json"), else: conn
      response = ModelSettingsServer.call(conn, c.path)
      assert response.status == expected
      refute response.resp_body =~ "synthetic-settings"
      refute response.resp_body =~ String.duplicate("a", 40)
    end

    {:ok, shown} = ModelSettings.show(c.config, "a")

    conn =
      Plug.Test.conn("POST", "/repositories/a", Jason.encode!(%{"defaults" => shown["defaults"], "revision" => 0, "workflow_version" => shown["workflow_version"]}))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> String.duplicate("a", 40))
      |> Plug.Conn.put_req_header("origin", c.config["origin"])
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert ModelSettingsServer.call(conn, c.path).status == 200
    assert ModelSettingsServer.call(conn, c.path).status == 409
    System.delete_env("GH16_ADMIN")
    assert {:error, :model_settings_admin_unavailable} = ModelSettingsServer.start_link(c.path)
    assert ModelSettingsServer.call(Plug.Test.conn("GET", "/repositories"), c.path).status == 401
  end

  test "channel controls expose graded, switch, fixed and unknown states only with exact fresh proofs", c do
    {:ok, s} = ModelSettings.settings(c.config, "a")
    registry = put_in(s.model_services, ["presets", "fixed"], Map.put(s.model_services["presets"]["coding"], "parameters", %{}))
    {:ok, registry} = ModelCatalog.register(registry, "fixed", "gpt-fixed", [])
    channel = ModelServices.channel_binding(registry["presets"]["fixed"])
    {:ok, template} = ModelServices.snapshot(%{s | model_services: registry}, "fixed", :coder, "test")
    fixed = Map.put(template, "model", "gpt-fixed")
    {:ok, registry} = ModelCatalog.attest(registry, fixed, F.proof(:coder))
    {:ok, registry} = ModelCatalog.register(registry, "fixed", "gpt-switch", ~w(none high))
    registry = put_in(registry, ["catalog", "fixed", "models", "gpt-switch", "discovery", channel, "reasoning_mode"], "switch")

    registry =
      Enum.reduce([:coder, :reviewer], registry, fn role, acc ->
        Enum.reduce(~w(none high), acc, fn effort, acc ->
          service = template |> Map.put("role", Atom.to_string(role)) |> Map.put("model", "gpt-switch") |> Map.put("parameters", %{"reasoning_effort" => effort})
          {:ok, acc} = ModelCatalog.attest(acc, service, F.proof(role))
          acc
        end)
      end)

    {:ok, registry} = ModelCatalog.register(registry, "fixed", "gpt-unknown", [])
    registry = put_in(registry, ["catalog", "fixed", "models", "gpt-unknown", "discovery", channel, "reasoning_mode"], "unknown")
    assert {:error, :model_reasoning_capability_unknown} = ModelCatalog.available(registry, Map.put(template, "model", "gpt-unknown"))
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 0, registry)
    {:ok, show} = ModelSettings.show(c.config, "a")
    fixed = Enum.find(show["roles"]["coder"], &(&1["selection"]["model"] == "gpt-fixed"))
    assert fixed["reasoning_mode"] == "fixed"
    assert fixed["selection"]["parameters"] == %{}
    assert fixed["state"] == "available"
    unknown = Enum.find(show["roles"]["coder"], &(&1["selection"]["model"] == "gpt-unknown"))
    assert unknown["reasoning_mode"] == "unknown"
    refute unknown["state"] == "available"

    for role <- ~w(coder reviewer) do
      choices = Enum.filter(show["roles"][role], &(&1["selection"]["model"] == "gpt-switch"))
      assert Enum.sort(Enum.map(choices, & &1["selection"]["parameters"]["reasoning_effort"])) == ~w(high none)
      assert Enum.all?(choices, &(&1["reasoning_mode"] == "switch" and &1["state"] == "available"))

      for choice <- choices do
        {:ok, current} = ModelSettings.show(c.config, "a")
        request = %{"defaults" => Map.put(current["defaults"], role, choice["selection"]), "revision" => current["revision"], "workflow_version" => current["workflow_version"]}
        assert {:ok, saved} = ModelSettings.save(c.config, "a", request)
        assert saved["effective_defaults"][role] == choice["selection"]
        other = if role == "coder", do: "reviewer", else: "coder"
        assert saved["defaults"][other] == current["defaults"][other]
        invalid = put_in(request, ["defaults", role, "parameters", "reasoning_effort"], "low")
        assert {:error, :model_reasoning_effort_unsupported} = ModelSettings.save(c.config, "a", %{invalid | "revision" => saved["revision"]})
        assert {:ok, ^saved} = ModelSettings.show(c.config, "a")
      end
    end

    stale = %{"defaults" => show["defaults"], "revision" => 1, "workflow_version" => "stale"}
    assert {:error, :model_services_conflict} = ModelSettings.save(c.config, "a", stale)
    service = Map.put(template, "model", "gpt-fixed")
    registry = put_in(registry, ["validations", ModelServices.binding(service), "expires_at"], DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1)))
    assert {:error, :model_validation_expired} = ModelCatalog.available(registry, service)

    {:ok, current} = ModelSettings.settings(c.config, "a")
    expiry = registry["validations"][ModelServices.binding(service)]["expires_at"]
    expired = put_in(current.model_services, ["validations", ModelServices.binding(service), "expires_at"], expiry)
    assert {:ok, _} = ModelServices.save(ModelServices.path(current), current.model_services, current.model_services["revision"], expired)
    {:ok, unchanged} = ModelSettings.show(c.config, "a")
    original = File.read!(ModelServices.path(current))

    for {model, parameters, reason} <- [
          {"gpt-unknown", %{}, :model_reasoning_capability_unknown},
          {"gpt-fixed", %{"reasoning_effort" => "high"}, :model_reasoning_effort_unsupported},
          {"gpt-fixed", %{}, :model_validation_expired}
        ] do
      selected = %{"preset" => "fixed", "model" => model, "parameters" => parameters}
      request = %{"defaults" => Map.put(unchanged["defaults"], "coder", selected), "revision" => unchanged["revision"], "workflow_version" => unchanged["workflow_version"]}
      assert {:error, ^reason} = ModelSettings.save(c.config, "a", request)
      assert File.read!(ModelServices.path(current)) == original
      assert {:ok, ^unchanged} = ModelSettings.show(c.config, "a")
    end

    illegal =
      put_in(registry, ["presets", "fixed", "provider"], "deepseek")
      |> put_in(["presets", "fixed", "adapter"], "deepseek_responses")
      |> put_in(["presets", "fixed", "parameters"], %{"reasoning_effort" => "medium"})

    assert {:error, :invalid_model_services} = ModelServices.validate(illegal)
  end

  test "malformed defaults and filesystem failures preserve persisted state with bounded retries", c do
    {:ok, shown} = ModelSettings.show(c.config, "a")
    request = %{"defaults" => shown["defaults"], "revision" => 0, "workflow_version" => shown["workflow_version"]}
    {:ok, first} = ModelSettings.save(c.config, "a", request)
    {:ok, settings} = ModelSettings.settings(c.config, "a")
    path = ModelServices.path(settings)
    original = File.read!(path)

    for selection <- [
          nil,
          [],
          42,
          %{},
          %{"preset" => "coding", "model" => "gpt-test", "parameters" => %{"reasoning_effort" => nil}},
          %{"preset" => "coding", "model" => "gpt-test", "parameters" => %{"temperature" => 1}},
          %{"preset" => "coding", "model" => "gpt-test", "parameters" => %{}, "secret" => "no"}
        ] do
      invalid = %{request | "revision" => 1, "defaults" => Map.put(shown["defaults"], "coder", selection)}
      assert {:error, :invalid_model_services} = ModelSettings.save(c.config, "a", invalid)
      assert File.read!(path) == original
    end

    File.mkdir!(path <> ".next")
    assert {:error, :eexist} = ModelSettings.save(c.config, "a", %{request | "revision" => 1})
    assert File.read!(path) == original
    File.rmdir!(path <> ".next")
    File.write!(path <> ".lock", "synthetic active writer")
    assert {:error, :model_services_busy} = ModelSettings.save(c.config, "a", %{request | "revision" => 1})
    assert File.read!(path) == original
    File.rm!(path <> ".lock")
    results = for _ <- 1..2, do: Task.async(fn -> ModelSettings.save(c.config, "a", %{request | "revision" => 1}) end)
    outcomes = Enum.map(results, &Task.await/1)
    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.any?(outcomes, &(&1 in [{:error, :model_services_busy}, {:error, :model_services_conflict}]))
    assert {:ok, latest} = ModelSettings.show(c.config, "a")
    assert latest["revision"] == 2
    assert latest["defaults"] == first["defaults"]
  end

  test "unsafe auth paths stay private and unknown future controls cannot become fixed choices", c do
    {:ok, settings} = ModelSettings.settings(c.config, "a")
    preset = %{settings.model_services["presets"]["coding"] | "credential_ref" => "auth_home:/private/administrator/auth"}
    registry = put_in(settings.model_services, ["presets", "oauth"], preset)
    {:ok, registry} = ModelCatalog.register(registry, "oauth", "gpt-test", [])
    assert {:ok, _} = ModelServices.save(ModelServices.path(settings), settings.model_services, 0, registry)
    {:ok, shown} = ModelSettings.show(c.config, "a")
    refute Jason.encode!(shown) =~ "/private/administrator"
    assert Enum.any?(shown["roles"]["coder"], &(&1["credential_ref"] == "auth_home:(configured)"))

    settings = %{settings | model_services: registry}
    discover = fn _, _ -> {:ok, [%{"model" => "gpt-future", "supportedReasoningEfforts" => [%{"reasoningEffort" => "future"}]}]} end
    assert {:ok, refreshed} = ModelCatalog.refresh(settings, "coding", discover: discover)
    channel = ModelServices.channel_binding(registry["presets"]["coding"])
    assert get_in(refreshed, ["catalog", "coding", "models", "gpt-future", "discovery", channel, "reasoning_mode"]) == "unknown"
    discover = fn _, _ -> {:ok, [%{"model" => "gpt-fixed", "supportedReasoningEfforts" => []}]} end
    assert {:ok, _} = ModelCatalog.refresh(settings, "coding", discover: discover)
    discover = fn _, _ -> {:ok, [%{"model" => "gpt-test", "supportedReasoningEfforts" => [], "reasoningMode" => "guessed"}]} end
    assert {:error, {:model_discovery_failed, failed}} = ModelCatalog.refresh(settings, "coding", discover: discover)
    assert failed["catalog"]["coding"]["models"] == registry["catalog"]["coding"]["models"]
  end

  @tag timeout: 120_000
  test "packaged management process starts independently and rereads defaults after restart", c do
    assert_packaged_restarts!(c, save_four_defaults!(c.config))
  end

  defp assert_packaged_restarts!(c, saved) do
    {build, 0} = System.cmd("timeout", ["--signal=KILL", "90s", "mix", "escript.build"], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
    assert build =~ "symphony" or build == ""
    executable = Path.expand("bin/symphony")
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    File.write!(c.path, Jason.encode!(Map.put(c.config, "port", port)))
    headers = [{"authorization", "Bearer " <> String.duplicate("a", 40)}]
    before_files = Map.new(~w(a b), &{&1, Enum.sort(File.ls!(c.config["repositories"][&1]["state_dir"]))})

    for _ <- 1..2 do
      child = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, args: ["--model-settings", c.path]])
      {:os_pid, pid} = Port.info(child, :os_pid)

      try do
        for id <- ~w(a b) do
          url = "http://127.0.0.1:#{port}/repositories/#{id}"

          response =
            Enum.reduce_while(1..40, nil, fn _, _ ->
              case Req.get(url, headers: headers, retry: false, connect_options: [timeout: 200], receive_timeout: 1000) do
                {:ok, response} ->
                  {:halt, response}

                _ ->
                  Process.sleep(50)
                  {:cont, nil}
              end
            end)

          assert %{status: 200, body: body} = response
          assert body == saved[id]
          assert Enum.sort(File.ls!(c.config["repositories"][id]["state_dir"])) == before_files[id]
        end
      after
        System.cmd("kill", ["-TERM", Integer.to_string(pid)])
        assert_receive {^child, {:exit_status, _}}, 5000
      end
    end
  end

  defp save_four_defaults!(config) do
    targets = %{"a" => [{:coder, "reviewing", "high"}, {:reviewer, "coding", "medium"}], "b" => [{:coder, "coding", "high"}, {:reviewer, "reviewing", "medium"}]}

    Enum.reduce(~w(a b), %{}, fn id, results ->
      {:ok, s} = ModelSettings.settings(config, id)

      registry =
        Enum.reduce(targets[id], s.model_services, fn {role, preset, effort}, acc ->
          {:ok, template} = ModelServices.snapshot(%{s | model_services: acc}, preset, role, "fixture")
          service = Map.put(template, "parameters", %{"reasoning_effort" => effort})
          {:ok, acc} = ModelCatalog.attest(acc, service, F.proof(role))
          acc
        end)

      assert {:ok, prepared} = ModelServices.save(ModelServices.path(s), s.model_services, 0, registry)
      invariant = Map.drop(prepared, ~w(defaults revision))
      other_id = if id == "a", do: "b", else: "a"
      {:ok, other_repo} = ModelSettings.show(config, other_id)

      for {role, preset, effort} <- targets[id] do
        {:ok, current} = ModelSettings.show(config, id)
        key = Atom.to_string(role)
        selected = %{"preset" => preset, "model" => "gpt-test", "parameters" => %{"reasoning_effort" => effort}}
        request = %{"workflow_version" => current["workflow_version"], "revision" => current["revision"], "defaults" => Map.put(current["defaults"], key, selected)}
        assert {:ok, saved} = ModelSettings.save(config, id, request)
        assert saved["revision"] == current["revision"] + 1
        assert saved["defaults"][key] == selected
        assert saved["effective_defaults"][key] == selected
        untouched = %{"coder" => "reviewer", "reviewer" => "coder"}[key]
        assert saved["defaults"][untouched] == current["defaults"][untouched]
        assert {:ok, ^other_repo} = ModelSettings.show(config, other_id)
        {:ok, persisted} = ModelServices.load(ModelServices.path(s), nil)
        assert Map.drop(persisted, ~w(defaults revision)) == invariant
        assert {:ok, ^saved} = ModelSettings.show(config, id)
      end

      {:ok, saved} = ModelSettings.show(config, id)
      Map.put(results, id, saved)
    end)
  end

  test "DeepSeek discovery does not infer depth from a model ID and reports safe failures", c do
    {:ok, s} = ModelSettings.settings(c.config, "a")
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "test")
    service = %{service | "provider" => "deepseek", "adapter" => "deepseek_responses", "model" => "deepseek-test", "parameters" => %{"reasoning_effort" => "max"}}
    assert :ok = ModelServices.validate_snapshot(service)

    assert {:ok, [%{"model" => "deepseek-test", "reasoningMode" => "unknown"}]} =
             DeepSeek.list_models(service,
               plug: fn conn ->
                 assert conn.request_path == "/v1/models"
                 assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-settings-coder"]
                 conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "deepseek-test"}]}))
               end
             )

    for {status, body} <- [{401, %{"error" => "synthetic-settings-coder"}}, {200, %{"data" => [%{"id" => "bad model"}]}}, {200, %{"data" => nil}}, {302, %{}}] do
      assert {:error, :model_discovery_failed} =
               DeepSeek.list_models(service, plug: fn conn -> conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, Jason.encode!(body)) end)
    end

    preset = Map.take(service, ~w(version provider adapter model parameters connection credential_ref))
    registry = put_in(s.model_services, ["presets", "coding"], preset)

    assert {:ok, refreshed} =
             ModelCatalog.refresh(%{s | model_services: registry}, "coding",
               plug: fn conn -> conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "deepseek-test"}]})) end
             )

    channel = ModelServices.channel_binding(service)
    assert get_in(refreshed, ["catalog", "coding", "models", "deepseek-test", "discovery", channel, "reasoning_mode"]) == "unknown"
    assert get_in(refreshed, ["catalog", "coding", "models", "deepseek-test", "discovery", channel, "source"]) == "provider"

    bad = Map.put(service, "credential_ref", "auth_home:/missing")
    assert {:error, :model_auth_route_incompatible} = ModelServices.connection_ready(bad)
    assert {:error, :model_discovery_failed} = DeepSeek.list_models(bad)
  end
end
