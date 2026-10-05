defmodule SymphonyElixir.MvpModelServicesTest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Mvp.Models
  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp.{Intake, ModelCatalog, ModelServices}

  setup do
    root = Path.join(System.tmp_dir!(), "gh12-services-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.put_env("GH12_CODER_KEY", "synthetic-coder-secret")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-reviewer-secret")

    on_exit(fn ->
      File.rm_rf!(root)
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    %{root: root, settings: F.settings(root)}
  end

  test "authorized commands accumulate by role and ID across both syntaxes, with explicit default", %{settings: s} do
    assert {:ok, initial} = Intake.resolve_comments([], s)
    assert initial.services["coder"]["source"] == "project_default"
    {:ok, reviewer_on_coding} = ModelServices.snapshot(s, "coding", :reviewer, "fixture")
    {:ok, registry} = ModelCatalog.attest(s.model_services, reviewer_on_coding, F.proof(:reviewer))
    s = %{s | model_services: registry}
    comments = [F.comment(30, "/symphony configs reviewer=default"), F.comment(10, "/symphony models coder=gpt-test"), F.comment(20, "/symphony configs reviewer=coding")]
    assert {:ok, selected} = Intake.resolve_comments(comments, s)
    assert selected.services["coder"]["id"] == "coding"
    assert selected.services["coder"]["source"] == "issue_comment:10:owner:models"
    assert selected.services["reviewer"]["id"] == "reviewing"
    assert selected.services["reviewer"]["source"] == "issue_comment:30:owner:configs"
    assert {:ok, _} = Intake.resolve_comments([F.comment(40, "/symphony models coder=default")], s)
    assert {:ok, ^initial} = Intake.resolve_comments([F.comment(1, "/symphony configs coder=bad", "stranger"), F.comment(2, "> /symphony configs coder=bad")], s)
  end

  test "malformed authorized selections stop intake, including earlier errors followed by defaults", %{settings: s} do
    for body <- [
          "/symphony configs",
          "/symphony configs coder=coding coder=reviewing",
          "/symphony configs diagnosis=coding",
          "/symphony configs coder=https://bad",
          "/symphony configs coder=coding\nprose",
          " /symphony configs coder=coding",
          "/symphony configs coder=coding token=secret",
          "/symphony configs coder=coding\t",
          "/symphony configs coder="
        ] do
      assert {:error, _} = Intake.resolve_comments([F.comment(1, body)], s)
    end

    assert {:error, :model_service_not_registered} = Intake.resolve_comments([F.comment(1, "/symphony configs coder=unknown"), F.comment(2, "/symphony configs coder=default")], s)
    assert {:error, :model_not_discovered} = Intake.resolve_comments([F.comment(1, "/symphony models coder=gpt-invented")], s)
    legacy = Map.delete(s, :model_services)
    assert {:error, :model_services_not_configured} = Intake.resolve_comments([F.comment(1, "/symphony configs coder=coding")], legacy)
  end

  test "same model in two configurations never shares connection, effort, credentials or capability evidence", %{settings: s} do
    {:ok, choices} = Intake.resolve_comments([], s)
    coder = choices.services["coder"]
    reviewer = choices.services["reviewer"]
    assert coder["model"] == reviewer["model"]
    refute coder["connection"] == reviewer["connection"]
    refute coder["parameters"] == reviewer["parameters"]
    refute coder["credential_ref"] == reviewer["credential_ref"]
    refute ModelServices.binding(coder) == ModelServices.binding(reviewer)
    assert {:error, :model_role_not_verified} = ModelCatalog.available(s.model_services, Map.put(coder, "role", "reviewer"))
    different_channel = put_in(coder, ["connection", "base_url"], "https://other.example/v1")
    assert {:error, :model_catalog_channel_unverified} = ModelCatalog.available(s.model_services, different_channel)
    context = %{settings: s, services: choices.services, models: Map.take(choices, [:coder, :reviewer])}
    assert {:ok, diagnosis} = ModelServices.options(context, :diagnosis)
    assert diagnosis[:model_service] == coder
    assert {:ok, options} = ModelServices.options(context, :reviewer)
    assert options[:model_service] == reviewer
    System.delete_env("GH12_REVIEWER_KEY")
    assert {:error, :model_credential_missing} = ModelServices.options(context, :reviewer)
    assert {:ok, _} = ModelServices.options(context, :coder)
  end

  test "persistent defaults are atomic, revision checked, safe on failed save and survive reload", %{root: root, settings: s} do
    file = ModelServices.path(s)
    registry = s.model_services
    assert {:ok, nil} = ModelServices.load(Path.join(root, "absent"), nil)
    assert {:ok, ^registry} = ModelServices.load(file, registry)
    assert {:ok, saved} = ModelServices.save(file, registry, 0, registry)
    assert saved["revision"] == 1
    raw = File.read!(file)
    assert {:error, :model_services_conflict} = ModelServices.save(file, registry, 0, registry)
    assert File.read!(file) == raw
    assert {:error, :invalid_model_services} = ModelServices.save(file, registry, 1, Map.put(registry, "secret", "do-not-save"))
    assert File.read!(file) == raw
    assert {:ok, ^saved} = ModelServices.load(file, nil)
    assert {:ok, shown} = Models.execute("show", s, [])
    assert shown["presets"]["coding"]["credential_configured"]
    refute Jason.encode!(shown) =~ "synthetic-coder-secret"
    changed = put_in(saved, ["presets", "coding", "parameters", "reasoning_effort"], "high")
    assert {:error, :model_service_version_required} = ModelServices.save(file, registry, 1, changed)
    changed = put_in(changed, ["presets", "coding", "version"], 2)
    assert {:error, :model_role_not_verified} = ModelServices.save(file, registry, 1, changed)
    {:ok, changed_service} = ModelServices.snapshot(%{s | model_services: changed}, "coding", :coder, "fixture")
    {:ok, changed} = ModelCatalog.attest(changed, changed_service, F.proof(:coder))
    assert {:ok, next} = ModelServices.save(file, registry, 1, changed)
    assert next["revision"] == 2
    File.write!(file <> ".lock", "held")
    assert {:error, :model_services_busy} = ModelServices.save(file, registry, 2, changed)
    File.rm!(file <> ".lock")
    File.write!(file <> ".next", "old uncompleted write")
    assert {:error, :eexist} = ModelServices.save(file, registry, 2, changed)
    assert {:ok, ^next} = ModelServices.load(file, nil)
    input = Path.join(root, "proposed.json")
    File.write!(input, Jason.encode!(next))
    assert {:ok, value} = Models.execute("save", s, ["2", input])
    assert value["revision"] == 3
    assert {:error, :model_services_save_failed} = Models.execute("save", s, ["bad", input])
    assert {:error, :invalid_model_service_command} = Models.execute("unknown", s, [])
    results = 1..8 |> Enum.map(fn _ -> Task.async(fn -> ModelServices.save(file, registry, 3, next) end) end) |> Task.await_many()
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 in [{:error, :model_services_busy}, {:error, :model_services_conflict}]))
    File.write!(file, "{")
    assert {:error, _} = ModelServices.load(file, nil)
    assert {:error, _} = ModelServices.read(s)
    assert {:error, _} = ModelServices.load(root, nil)
  end

  test "strict registry rejects malformed nested data, unsafe URLs, credential values and unsupported parameters", %{settings: s} do
    registry = s.model_services

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(registry, "revision", -1),
          Map.put(registry, "presets", []),
          put_in(registry, ["presets", "coding"], "x"),
          Map.put(registry, "defaults", []),
          put_in(registry, ["defaults", "coder"], "absent"),
          Map.put(registry, "catalog", []),
          Map.put(registry, "validations", [])
        ] do
      assert {:error, :invalid_model_services} = ModelServices.validate(invalid)
    end

    for {key, value} <- [
          {"unknown_field", true},
          {"version", 0},
          {"model", "gpt-*"},
          {"credential_ref", "literal-secret"},
          {"credential_ref", "env:a;echo"},
          {"credential_ref", "auth_home:relative"},
          {"parameters", []},
          {"parameters", %{"temperature" => 1}},
          {"parameters", %{"reasoning_effort" => "ultra"}},
          {"connection", nil},
          {"connection", %{"base_url" => "https://user:key@host/v1", "protocol" => "responses"}},
          {"connection", %{"base_url" => "https://host/v1?key=x", "protocol" => "responses"}},
          {"connection", %{"base_url" => "http://host/v1", "protocol" => "responses"}}
        ] do
      assert {:error, :invalid_model_services} = ModelServices.validate(put_in(registry, ["presets", "coding", key], value))
    end

    assert {:error, :invalid_model_service_snapshot} = ModelServices.validate_snapshot(nil)
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    assert :ok = ModelServices.validate_snapshot(service)
    assert {:error, _} = ModelServices.validate_snapshot(Map.put(service, "secret", "bad"))
    assert {:error, :invalid_model_services} = ModelServices.load("/missing-model-registry", %{})
    assert {:error, :model_services_not_configured} = ModelServices.read(%{s | model_services: nil})
  end

  test "discovery records all pages' entries as pending; validation automatically enables only its binding", %{settings: s} do
    defaults = s.model_services["defaults"]

    discover = fn service, _ ->
      assert service["credential_ref"] == "env:GH12_CODER_KEY"
      {:ok, [%{"model" => "gpt-next", "supportedReasoningEfforts" => [%{"reasoningEffort" => "medium"}]}]}
    end

    assert {:ok, registry} = ModelCatalog.refresh(s, "coding", discover: discover)
    s = %{s | model_services: registry}
    {:ok, template} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    service = Map.put(template, "model", "gpt-next")
    assert ModelCatalog.status(registry, service)["state"] == "pending_validation"
    assert {:ok, available} = ModelCatalog.attest(registry, service, F.proof(:coder))
    assert :ok = ModelCatalog.available(available, service)
    assert available["defaults"] == defaults
    assert ModelCatalog.status(available, service)["state"] == "available"
    assert {:ok, choices} = Intake.resolve_comments([F.comment(1, "/symphony models coder=gpt-next")], %{s | model_services: available})
    assert choices.coder == "gpt-next"
    assert choices.reviewer == "gpt-test"
    offline = fn _, _ -> {:error, :offline} end
    assert {:error, {:model_discovery_failed, failed}} = ModelCatalog.refresh(s, "coding", discover: offline)
    assert failed["catalog"]["coding"]["models"] == registry["catalog"]["coding"]["models"]
    assert failed["catalog"]["coding"]["refreshed_at"] == registry["catalog"]["coding"]["refreshed_at"]
    assert failed["catalog"]["coding"]["error"] == "discovery_failed"

    for malformed <- [nil, [%{}], [%{"model" => "bad id", "supportedReasoningEfforts" => []}], [%{"model" => "gpt-bad", "supportedReasoningEfforts" => ["high"]}]] do
      discover_invalid = fn _, _ -> {:ok, malformed} end
      assert {:error, {:model_discovery_failed, _}} = ModelCatalog.refresh(s, "coding", discover: discover_invalid)
    end
  end

  test "catalog distinguishes disabled, incompatible, expired, undiscovered and unsupported before any call", %{settings: s} do
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    registry = s.model_services
    disabled = put_in(registry, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
    assert {:error, :model_disabled} = ModelCatalog.available(disabled, service)
    assert ModelCatalog.status(disabled, service)["state"] == "disabled"
    assert {:error, :model_provider_not_supported} = ModelCatalog.available(registry, Map.put(service, "provider", "mock-provider"))
    assert {:error, :model_protocol_incompatible} = ModelCatalog.available(registry, Map.put(service, "model", "other-model"))
    assert {:error, :model_service_revoked} = ModelCatalog.available(put_in(registry, ["presets"], %{}), service)
    unsupported = put_in(service, ["parameters", "reasoning_effort"], "low")
    assert {:error, :model_reasoning_effort_unsupported} = ModelCatalog.available(registry, unsupported)
    assert ModelCatalog.status(registry, put_in(service, ["parameters", "reasoning_effort"], "low"))["state"] == "incompatible"
    unknown = Map.put(service, "model", "gpt-unknown")
    assert ModelCatalog.status(registry, unknown)["state"] == "undiscovered"
    binding = ModelServices.binding(service)
    expired = put_in(registry, ["validations", binding, "expires_at"], "2000-01-01T00:00:00Z")
    assert {:error, :model_validation_expired} = ModelCatalog.available(expired, service)
    incompatible = put_in(registry, ["validations", binding, "capabilities"], [])
    assert {:error, :model_role_incompatible} = ModelCatalog.available(incompatible, service)
    assert {:error, :model_role_not_verified} = ModelCatalog.available(put_in(registry, ["validations", binding, "role"], "reviewer"), service)
    assert {:error, :invalid_model_capability_evidence} = ModelCatalog.attest(registry, service, %{})
    assert {:error, :invalid_model_capability_evidence} = ModelCatalog.attest(registry, service, Map.put(F.proof(:coder), "validated_at", "2099-01-01T00:00:00Z"))
    assert {:error, _} = ModelCatalog.register(registry, "absent", "gpt-next", ["high"])
    assert {:error, _} = ModelCatalog.register(registry, "coding", "gpt-next", ["invalid"])
  end

  test "inference probes demand an actual tool event and exact structured output; no success from discovery", %{root: root, settings: s} do
    {s, root} = F.probe_settings(s, root)

    probe = fn workspace, _prompt, _issue, opts ->
      [file] = Path.wildcard(Path.join(workspace, "model-capability-probe-*"))
      assert opts[:read_only]
      environment = opts[:execution_environment]
      config = File.read!(Path.join(environment.codex_home, "environments.toml"))
      assert config =~ "include_local = false"
      assert config =~ "--read-only-workspace"
      refute File.exists?(Path.join(workspace, "auth.json"))
      assert opts[:model_service]["role"] == "reviewer"
      opts[:on_message].(%{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "exitCode" => 0}}}})
      {:ok, %{output_text: Jason.encode!(%{"token" => File.read!(file)})}}
    end

    assert {:ok, updated} = ModelCatalog.verify(s, "reviewing", "gpt-test", :reviewer, root, probe: F.sandbox_probe(probe))
    {:ok, service} = ModelServices.snapshot(s, "reviewing", :reviewer, "fixture")
    proof = updated["validations"][ModelServices.binding(service)]
    assert proof["source"] == "inference" and is_nil(proof["actual_model"])
    assert Path.wildcard(Path.join(root, "model-capability-probe-*")) == []

    assert {:error, :model_tool_probe_failed} =
             ModelCatalog.verify(s, "coding", "gpt-test", :coder, root,
               probe:
                 F.sandbox_probe(fn w, _, _, _ ->
                   [file] = Path.wildcard(Path.join(w, "model-capability-probe-*"))
                   {:ok, %{output_text: Jason.encode!(%{"token" => File.read!(file)})}}
                 end)
             )

    failures = [{:error, :permission_denied}, {:ok, %{output_text: "invalid"}}, {:ok, %{output_text: "{}"}}, {:ok, %{output_text: Jason.encode!(%{"token" => "wrong"})}}]

    for result <- failures do
      failed_probe = fn _, _, _, _ -> result end
      assert {:error, :model_inference_validation_failed} = ModelCatalog.verify(s, "coding", "gpt-test", :coder, root, probe: F.sandbox_probe(failed_probe))
    end

    timeout = fn _, _, _, _ -> {:error, :turn_timeout} end
    assert {:error, :turn_timeout} = ModelCatalog.verify(s, "coding", "gpt-test", :coder, root, probe: F.sandbox_probe(timeout))
    forbidden = fn _, _, _, _ -> {:error, {:model_call_failed, :model_account_forbidden}} end
    assert {:error, :model_account_forbidden} = ModelCatalog.verify(s, "coding", "gpt-test", :coder, root, probe: F.sandbox_probe(forbidden))
    assert {:error, :invalid_model_role} = ModelCatalog.verify(s, "coding", "gpt-test", :diagnosis, root)
    assert {:error, :model_not_discovered} = ModelCatalog.verify(s, "coding", "gpt-unknown", :coder, root)
  end

  test "frozen services survive default and version changes, but honor revocation", %{settings: s} do
    {:ok, choices} = Intake.resolve_comments([], s)
    context = %{settings: s, services: choices.services, models: Map.take(choices, [:coder, :reviewer])}

    changed =
      s.model_services |> put_in(["defaults", "coder"], "reviewing") |> put_in(["presets", "coding", "version"], 2) |> put_in(["presets", "coding", "connection", "base_url"], "https://new.example/v1")

    {:ok, default_service} = ModelServices.snapshot(%{s | model_services: changed}, "reviewing", :coder, "fixture")
    {:ok, changed} = ModelCatalog.attest(changed, default_service, F.proof(:coder))
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 0, changed)
    assert {:ok, options} = ModelServices.options(context, :coder)
    assert options[:model_service] == choices.services["coder"]
    revoked = put_in(changed, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 1, revoked)
    assert {:error, :model_disabled} = ModelServices.options(context, :coder)
    assert {:ok, _} = ModelServices.options(context, :reviewer)
    assert {:error, :legacy_model_service_snapshot_missing} = ModelServices.run("unused", "unused", %{}, [])
    assert {:ok, [model: "x"]} = ModelServices.options(%{models: %{coder: "x"}}, :diagnosis)
  end

  test "account rotation invalidates discovery, evidence and already frozen calls", %{settings: s} do
    {:ok, choices} = Intake.resolve_comments([], s)
    context = %{settings: s, services: choices.services, models: Map.take(choices, [:coder, :reviewer])}
    original = choices.services["coder"]["credential_identity"]
    System.put_env("GH12_CODER_KEY", "synthetic-new-account")
    assert {:error, :model_credential_changed} = ModelServices.options(context, :coder)
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "rotation")
    refute service["credential_identity"] == original
    assert {:error, :model_catalog_channel_unverified} = ModelCatalog.available(s.model_services, service)
    {:ok, registry} = ModelCatalog.register(s.model_services, "coding", "gpt-test", ~w(medium high))
    assert {:error, :model_role_not_verified} = ModelCatalog.available(registry, service)
    {:ok, registry} = ModelCatalog.attest(registry, service, F.proof(:coder))
    assert :ok = ModelCatalog.available(registry, service)
    assert {:ok, _} = ModelServices.options(context, :reviewer)
    System.delete_env("GH12_CODER_KEY")
    assert {:error, :model_credential_missing} = Intake.resolve_comments([], s)
  end

  test "registry metadata, evidence and snapshots fail closed for malformed types", %{settings: s} do
    registry = s.model_services
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "fixture")

    for value <- [nil, 10, [], %{}] do
      invalid = put_in(registry, ["catalog", "coding"], value)
      assert {:error, :invalid_model_services} = ModelServices.validate(invalid)
    end

    for value <- [nil, [], %{}, %{"reasoning_efforts" => [], "disabled" => false, "discovery" => false}] do
      invalid = put_in(registry, ["catalog", "coding", "models", "gpt-test"], value)
      assert {:error, :invalid_model_services} = ModelServices.validate(invalid)
    end

    assert {:error, :invalid_model_services} = ModelServices.validate(put_in(registry, ["catalog", "coding", "refreshed_at"], 10))
    metadata = registry["catalog"]["coding"]["models"]["gpt-test"]
    invalid_name = put_in(registry["catalog"]["coding"]["models"]["bad id"], metadata)
    assert {:error, :invalid_model_services} = ModelServices.validate(invalid_name)
    invalid_proof = put_in(registry, ["validations", ModelServices.binding(service)], [])
    assert {:error, :invalid_model_services} = ModelServices.validate(invalid_proof)
    assert {:error, :invalid_model_service_snapshot} = ModelServices.validate_snapshot(Map.put(service, "credential_identity", "bad"))
    assert {:error, :invalid_model_service_snapshot} = ModelServices.validate_snapshot(Map.put(service, "capability_evidence", []))
    context = %{settings: %{s | model_services: nil}, services: %{"coder" => service}}
    assert {:error, :model_services_not_configured} = ModelServices.options(context, :coder)
    assert {:error, :invalid_model_services} = ModelServices.validate(put_in(registry, ["presets", "coding", "version"], 1.0))
    unverified = put_in(s, [:model_services, "validations"], %{})

    {unverified, probe_workspace} = F.probe_settings(unverified, s.state_dir)

    tool_failure = fn workspace, _, _, options ->
      options[:on_message].(%{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "exitCode" => 1}}}})
      [file] = Path.wildcard(Path.join(workspace, "model-capability-probe-*"))
      {:ok, %{output_text: Jason.encode!(%{"token" => File.read!(file)})}}
    end

    assert {:error, :model_tool_probe_failed} = ModelCatalog.verify(unverified, "coding", "gpt-test", :coder, probe_workspace, probe: F.sandbox_probe(tool_failure))
    assert {:error, :model_services_not_configured} = Models.execute("register", %{s | model_services: nil}, ["coding", "gpt-next"])
  end

  test "provider error categories distinguish retryable failures from permission and quota stops" do
    cases = [
      {401, :model_account_forbidden},
      {403, :model_account_forbidden},
      {429, :model_rate_limited},
      {"insufficient_quota", :model_quota_exhausted},
      {"model_not_found", :model_not_found},
      {503, :model_service_unavailable}
    ]

    for {code, expected} <- cases do
      assert ModelServices.failure_reason({:response_error, %{"code" => code}}) == {:model_call_failed, expected}
      assert ModelServices.failure_reason({:turn_failed, %{"error" => %{"code" => code}}}) == {:model_call_failed, expected}
    end

    assert ModelServices.failure_reason({:response_error, %{"code" => "unknown"}}) == {:response_error, %{"code" => "unknown"}}
    assert ModelServices.failure_reason({:turn_failed, %{"error" => "permission denied"}}) == {:turn_failed, %{"error" => "permission denied"}}
    assert ModelServices.failure_reason(:turn_timeout) == :turn_timeout
  end

  test "local management entrypoint persists manual evidence, reports safe failures and never starts scheduling", %{root: root, settings: s} do
    state = Path.join(root, "state")
    s = %{s | state_dir: state}
    workflow = Path.join(root, "MODELS.md")

    config = %{
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "tracker" => %{"kind" => "linear", "api_key" => "synthetic-token", "project_slug" => "test-project", "required_labels" => ["ready"]},
      "codex" => %{"command" => s.model_command},
      "mvp" => %{
        "enabled" => true,
        "state_dir" => state,
        "coder_model" => "gpt-test",
        "reviewer_model" => "gpt-test",
        "allowed_models" => ["gpt-test"],
        "allowed_actors" => ["owner"],
        "checks" => [["true"]],
        "model_services" => s.model_services
      }
    }

    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nPrompt\n")
    output = ExUnit.CaptureIO.capture_io(fn -> Models.run(["show", workflow]) end)
    assert Jason.decode!(output)["presets"]["coding"]["credential_configured"]
    assert Workflow.workflow_file_path() == workflow
    assert Config.settings!().workspace.root == Path.join(root, "workspaces")
    assert Config.settings!().codex.command == s.model_command
    assert_raise Mix.Error, ~r/Usage/, fn -> Models.run([]) end
    assert_raise Mix.Error, ~r/Cannot load/, fn -> Models.run(["show", Path.join(root, "absent")]) end
    assert_raise Mix.Error, ~r/invalid_model_service_command/, fn -> Models.run(["invalid", workflow]) end
    assert {:ok, saved} = Models.execute("register", s, ["coding", "gpt-manual", "medium"])
    assert saved["revision"] == 1
    {:ok, registry} = ModelServices.load(ModelServices.path(s), nil)
    s = %{s | model_services: registry}
    proof = Path.join(root, "proof.json")
    File.write!(proof, Jason.encode!(F.proof(:coder)))
    assert {:ok, attested} = Models.execute("attest", s, ["coding", "gpt-manual", "coder", proof])
    assert attested["revision"] == 2
    File.write!(proof, "{")
    assert_raise Mix.Error, ~r/invalid_model_service_operation/, fn -> Models.run(["attest", workflow, "coding", "gpt-manual", "coder", proof]) end
    File.write!(proof, "{}")
    assert {:error, :invalid_model_capability_evidence} = Models.execute("attest", s, ["coding", "gpt-manual", "coder", proof])
    assert {:error, :model_not_discovered} = Models.execute("verify", s, ["coding", "gpt-missing", "coder", root])
    assert {:error, :model_service_not_registered} = Models.execute("register", s, ["absent", "gpt-next", "high"])
    # Missing credentials refuse discovery before a subprocess starts.
    # Keep the directory and record the failure.
    {:ok, current} = ModelServices.load(ModelServices.path(s), nil)
    s = %{s | model_services: current}
    System.delete_env("GH12_CODER_KEY")
    assert {:error, :model_discovery_failed} = Models.execute("refresh", s, ["coding"])
    {:ok, failed} = ModelServices.load(ModelServices.path(s), nil)
    assert failed["catalog"]["coding"]["error"] == "discovery_failed"
    assert failed["catalog"]["coding"]["models"] == current["catalog"]["coding"]["models"]
    stale = %{s | model_services: current}
    assert {:error, :model_services_conflict} = Models.execute("refresh", stale, ["coding"])
    System.put_env("GH12_CODER_KEY", "synthetic-coder-secret")
    assert {:ok, _} = ModelServices.save(Path.join(root, "first.json"), nil, 0, registry)
  end

  test "bounded retries, malformed Review and diagnosis use the frozen service after a default change", %{root: root, settings: s} do
    alias SymphonyElixir.Mvp.{Attempts, Receipt, Recovery}
    {:ok, choices} = Intake.resolve_comments([], s)
    {:ok, policy} = Recovery.settings(%{"enabled" => true})
    receipt = Path.join(root, "attempts.json")

    File.write!(
      receipt,
      Jason.encode!(%{
        "status" => "coding",
        "rounds" => [%{"evidence" => root, "usage" => %{}}],
        "recovery" => %{"policy" => policy, "started_at" => DateTime.to_iso8601(DateTime.utc_now()), "agent_attempts" => 0, "events" => []}
      })
    )

    context = %{workspace: root, receipt: receipt, services: choices.services, models: Map.take(choices, [:coder, :reviewer]), issue: %{}, settings: Map.put(s, :recovery, policy), limit: 0, opts: []}

    agent = fn _, _, _, opts ->
      assert opts[:model_service] == choices.services["coder"]
      count = Receipt.read(receipt)["recovery"]["agent_attempts"]

      if count == 1 do
        proposed = put_in(s.model_services, ["defaults", "coder"], "reviewing")
        {:ok, switched} = ModelServices.snapshot(%{s | model_services: proposed}, "reviewing", :coder, "fixture")
        {:ok, proposed} = ModelCatalog.attest(proposed, switched, F.proof(:coder))
        {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 0, proposed)
        {:error, {:model_call_failed, :model_rate_limited}}
      else
        {:ok, %{output_text: "fixed", actual_model: "gpt-confirmed"}}
      end
    end

    assert {:ok, _} = Attempts.run(%{context | opts: [agent: agent]}, :coder, "code", fn -> :ok end)
    after_retry = Receipt.read(receipt)
    requests = List.last(after_retry["rounds"])["model_requests"]
    assert requests["coder_attempt_1"]["actual_model"] == nil
    assert requests["coder_attempt_2"]["actual_model"] == "gpt-confirmed"
    assert requests["coder_attempt_2"]["provider"] == "openai"
    assert after_retry["usage"]["total_tokens"]["complete"] == false
    assert after_retry["usage"]["total_tokens"]["observed"] == nil

    diagnosis = fn _, _, _, opts ->
      assert opts[:model_service] == choices.services["coder"]
      assert opts[:read_only] and opts[:output_schema] == Recovery.schema()
      {:ok, %{output_text: Jason.encode!(%{action: "repair_code", summary: "diagnosed", steps: ["fix"], external_conditions: []})}}
    end

    assert {:ok, _} = Attempts.run(%{context | opts: [agent: diagnosis]}, :diagnosis, "diagnose", fn -> :ok end)

    review = fn _, _, _, opts ->
      assert opts[:model_service] == choices.services["reviewer"]
      assert opts[:read_only]
      count = Receipt.read(receipt)["recovery"]["agent_attempts"]
      {:ok, %{output_text: if(count == 4, do: "prose", else: Jason.encode!(%{approved: true, summary: "valid"}))}}
    end

    assert {:ok, _} = Attempts.run(%{context | opts: [agent: review]}, :reviewer, "review", fn -> :ok end)
    System.delete_env("GH12_CODER_KEY")
    assert {:error, :model_credential_missing} = Attempts.run(%{context | opts: [agent: fn _, _, _, _ -> flunk("credential revoked") end]}, :coder, "code", fn -> :ok end)
  end

  test "safe references and private home files contain no API key values", %{root: root, settings: s} do
    {:ok, service} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    assert {:ok, credential} = ModelServices.credential(service["credential_ref"])
    assert :ok = ModelServices.write_home(root, service, credential)
    config = File.read!(Path.join(root, "config.toml"))
    assert config =~ "coding.example"
    assert config =~ "medium"
    refute config =~ "synthetic-coder-secret"
    assert {:error, :eexist} = ModelServices.write_home(root, service, credential)
    assert {:error, :model_credential_missing} = ModelServices.credential("not-a-reference")
    auth = Path.join(root, "auth")
    File.mkdir!(auth)
    assert {:error, :model_credential_missing} = ModelServices.credential("auth_home:" <> auth)
    File.write!(Path.join(auth, "auth.json"), "bad")
    assert {:error, :model_credential_invalid} = ModelServices.credential("auth_home:" <> auth)
    File.write!(Path.join(auth, "auth.json"), "{\"test\":true}")
    assert {:ok, {:home, ^auth}} = ModelServices.credential("auth_home:" <> auth)
    private = Path.join(root, "private")
    File.mkdir!(private)
    assert :ok = ModelServices.write_home(private, put_in(service, ["parameters"], %{}), {:home, auth})
    assert File.read!(Path.join(private, "config.toml")) =~ "requires_openai_auth = true"
    assert {:ok, nil} = ModelServices.load(Path.join(root, "missing"), nil)
    assert {:ok, frozen} = ModelServices.freeze(%{coder: "old", reviewer: "old-review"}, s)
    assert frozen["coder"]["source"] == "legacy_migration"
    assert {:ok, ^frozen} = ModelServices.freeze(%{services: frozen}, s)
    assert :ok = ModelServices.validate_snapshot(frozen["coder"])
  end

  test "ChatGPT auth freezes the Codex Responses route while API keys retain their channel", %{root: root, settings: s} do
    home = Path.join(root, "chatgpt-auth")
    File.mkdir!(home)
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"tokens" => %{"access_token" => "synthetic-chatgpt-token"}}))
    s = Map.put(s, :sandbox, %{"auth_home" => home})
    assert {:ok, frozen} = ModelServices.freeze(%{coder: "gpt-test", reviewer: "gpt-test"}, s, environment: fn _ -> nil end)
    service = frozen["coder"]
    assert service["connection"]["base_url"] == "https://chatgpt.com/backend-api/codex"
    assert :ok = ModelServices.connection_ready(service)
    private = Path.join(root, "chatgpt-private")
    File.mkdir!(private)
    assert :ok = ModelServices.write_home(private, service, {:home, home})
    config = File.read!(Path.join(private, "config.toml"))
    assert config =~ ~s(model_provider = "openai")
    assert config =~ "https://chatgpt.com/backend-api/codex"
    refute config =~ "api.openai.com/v1"
    refute config =~ "synthetic-chatgpt-token"
    wrong = put_in(service, ["connection", "base_url"], "https://other.example/v1")
    assert {:error, :model_auth_route_incompatible} = ModelServices.connection_ready(wrong)
    assert {:error, :model_auth_route_incompatible} = ModelServices.write_home(root, wrong, {:home, home})
    {:ok, api} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    assert api["connection"]["base_url"] == "https://coding.example/v1"
    registry = put_in(s.model_services, ["presets", "coding", "credential_ref"], "auth_home:" <> home)
    registry = put_in(registry, ["presets", "coding", "connection", "base_url"], "https://api.openai.com/v1")
    {:ok, selected} = ModelServices.snapshot(%{s | model_services: registry}, "coding", :coder, "fixture")
    assert selected["connection"] == service["connection"]
    assert ModelServices.channel_binding(registry["presets"]["coding"]) == ModelServices.channel_binding(selected)
  end

  test "legacy freezing preserves auth references and current restrictions without inventing evidence", %{root: root, settings: s} do
    home = Path.join(root, "legacy-auth")
    File.mkdir!(home)
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"token" => "synthetic-legacy-token"}))
    s = Map.put(s, :sandbox, %{"auth_home" => home})
    models = %{coder: "gpt-test", reviewer: "gpt-test"}
    assert {:ok, services} = ModelServices.freeze(models, s, environment: fn _ -> nil end)
    service = services["coder"]
    assert service["credential_ref"] == "auth_home:" <> home
    assert is_binary(service["credential_identity"])
    assert is_nil(service["capability_evidence"])
    assert :ok = ModelServices.identity_matches(service)
    context = %{models: models, services: services, settings: Map.put(s, :allowed_models, ["gpt-test"])}
    assert {:ok, options} = ModelServices.options(context, :coder)
    assert options[:model_service] == service
    assert {:ok, _} = ModelServices.options(put_in(context.settings.model_services, nil), :coder)
    assert {:error, :model_service_revoked} = ModelServices.options(put_in(context.settings.allowed_models, []), :coder)
    disabled = put_in(context.settings.model_services["disabled_models"], ["gpt-test"])
    assert {:error, :model_disabled} = ModelServices.options(disabled, :coder)
    assert {:ok, env} = ModelServices.freeze(models, s, environment: fn name -> if name == "OPENAI_API_KEY", do: "synthetic", else: nil end)
    assert env["coder"]["credential_ref"] == "env:OPENAI_API_KEY"
    assert :ok = ModelServices.credential_boundary(service, [nil, Path.join(root, "workspace")])
    assert {:error, :model_credential_untrusted} = ModelServices.credential_boundary(service, [root])
    loop = Path.join(root, "loop-auth")
    File.mkdir!(loop)
    File.ln_s!(Path.join(loop, "auth.json"), Path.join(loop, "auth.json"))
    assert {:error, :model_credential_untrusted} = ModelServices.credential_boundary(Map.put(service, "credential_ref", "auth_home:" <> loop), [])
    missing = Map.put(service, "credential_ref", "auth_home:" <> Path.join(root, "missing"))
    assert {:error, :model_credential_untrusted} = ModelServices.credential_boundary(missing, [root])
    link = Path.join(root, "linked-auth")
    File.mkdir!(link)
    File.ln_s!(Path.join(home, "auth.json"), Path.join(link, "auth.json"))
    assert {:error, :model_credential_untrusted} = ModelServices.credential_boundary(Map.put(service, "credential_ref", "auth_home:" <> link), [home])
  end

  test "management shows per-role availability and refuses secret-bearing commands", %{settings: s} do
    assert {:ok, shown} = ModelServices.read(s)
    assert shown["availability"]["coding"]["gpt-test"]["coder"]["state"] == "available"
    assert shown["availability"]["coding"]["gpt-test"]["reviewer"]["state"] == "pending_validation"

    for command <- [nil, "", "codex app-server\n", "API_KEY=secret codex", "codex --api-key secret", "codex --token secret"] do
      unsafe = %{s | model_command: command}
      assert {:error, :model_service_command_unsafe} = ModelServices.snapshot(unsafe, "coding", :coder, "fixture")
      assert {:error, :model_service_command_unsafe} = ModelServices.freeze(%{coder: "gpt-test", reviewer: "gpt-test"}, unsafe)
      assert {:ok, refused} = ModelServices.read(unsafe)
      assert refused["availability"]["coding"]["gpt-test"]["coder"]["reason"] == "model_service_command_unsafe"
    end
  end

  test "new channel discovery cannot alter a frozen channel's supported parameters", %{settings: s} do
    {:ok, old} = ModelServices.snapshot(s, "coding", :coder, "fixture")
    changed = put_in(s.model_services["presets"]["coding"]["connection"]["base_url"], "https://new.example/v1")
    discover = fn _, _ -> {:ok, [%{"model" => "gpt-test", "supportedReasoningEfforts" => [%{"reasoningEffort" => "low"}, %{"reasoningEffort" => "future-effort"}]}]} end
    assert {:ok, registry} = ModelCatalog.refresh(changed, "coding", discover: discover)
    assert :ok = ModelCatalog.available(registry, old)
    assert ModelCatalog.status(registry, old)["channel_discovery"]["reasoning_efforts"] == ["medium", "high"]
    {:ok, current} = ModelServices.snapshot(%{s | model_services: registry}, "coding", :coder, "fixture")
    assert {:error, :model_reasoning_effort_unsupported} = ModelCatalog.available(registry, current)
    assert registry["catalog"]["coding"]["models"]["gpt-test"]["reasoning_efforts"] == ["low"]
    channel = ModelServices.channel_binding(old)

    for value <- [nil, "timestamp", %{}, %{"discovered_at" => false, "reasoning_efforts" => [], "source" => "manual"}] do
      invalid = put_in(registry["catalog"]["coding"]["models"]["gpt-test"]["discovery"][channel], value)
      assert {:error, :invalid_model_services} = ModelServices.validate(invalid)
    end
  end
end
