defmodule SymphonyElixir.MvpModelAuthorizationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp.{Attempts, Config, Intake, ModelCatalog, ModelServices, Recovery}

  setup do
    root = Path.join(System.tmp_dir!(), "gh12-authorization-#{System.unique_integer([:positive])}")
    System.put_env("GH12_CODER_KEY", "synthetic-coder")
    System.put_env("GH12_REVIEWER_KEY", "synthetic-reviewer")

    on_exit(fn ->
      File.rm_rf!(root)
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    %{root: root, settings: F.settings(root)}
  end

  test "reloaded embedded authority revokes frozen roles before Review, diagnosis and coding", %{settings: initial, root: root} do
    for role <- [:coder, :reviewer], change <- [:disable, :remove_preset, :remove_evidence, :expire_evidence] do
      s = alternate(initial, role)
      bind!(s)
      assert {:ok, s} = Config.settings()
      {:ok, selected} = Intake.resolve_comments([F.comment(1, "/symphony configs #{role}=alternate")], s)
      service = selected.services[Atom.to_string(role)]
      context = attempt_context(root, s, selected)
      assert {:ok, opts} = ModelServices.options(context, role)
      assert opts[:model_service] == service
      refute File.exists?(ModelServices.path(s))

      {registry, error} = revoke(s.model_services, service, change)
      bind!(%{s | model_services: registry})
      assert {:ok, current} = Config.settings()
      assert current.model_services == registry
      assert context.settings.model_services == s.model_services

      for invocation <- if(role == :coder, do: [:coder, :diagnosis], else: [:reviewer]) do
        assert {:error, ^error} = Attempts.run(context, invocation, "must not start", fn -> :ok end)
      end

      other = if role == :coder, do: :reviewer, else: :coder
      assert {:ok, unchanged} = ModelServices.options(context, other)
      assert unchanged[:model_service] == selected.services[Atom.to_string(other)]
    end
  end

  test "reloaded defaults and routing cannot replace frozen execution or its authority path", %{settings: s, root: root} do
    bind!(s)
    {:ok, s} = Config.settings()
    {:ok, selected} = Intake.resolve_comments([], s)
    context = attempt_context(root, s, selected)

    changed =
      s.model_services
      |> put_in(["defaults", "coder"], "reviewing")
      |> put_in(["presets", "coding", "version"], 2)
      |> put_in(["presets", "coding", "parameters", "reasoning_effort"], "high")
      |> put_in(["presets", "coding", "connection", "base_url"], "https://changed.example/v1")
      |> put_in(["presets", "coding", "credential_ref"], "env:GH12_REVIEWER_KEY")

    bind!(%{s | model_services: changed, model_command: "new-command app-server"})

    for role <- [:coder, :reviewer, :diagnosis] do
      assert {:ok, options} = ModelServices.options(context, role)
      key = if role == :reviewer, do: "reviewer", else: "coder"
      assert options[:model_service] == selected.services[key]
    end

    # A process-global workflow switch cannot change this task's authority.
    bind!(F.settings(Path.join(root, "other")))
    revoked = put_in(changed, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
    F.write_authority!(%{s | model_services: revoked})
    assert {:error, :model_disabled} = ModelServices.options(context, :coder)
    assert {:ok, _} = ModelServices.options(context, :reviewer)
  end

  test "original persistent registry retains priority and read failures cannot expose raw data", %{settings: s, root: root} do
    bind!(s)
    {:ok, s} = Config.settings()
    {:ok, selected} = Intake.resolve_comments([], s)
    context = attempt_context(root, s, selected)
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 0, s.model_services)
    revoked = put_in(s.model_services, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
    bind!(%{s | state_dir: Path.join(root, "new-state"), model_services: revoked})
    assert {:ok, opts} = ModelServices.options(context, :coder)
    assert opts[:model_service] == selected.services["coder"]
    assert {:ok, _} = ModelServices.save(ModelServices.path(s), s.model_services, 1, revoked)
    assert {:error, :model_disabled} = ModelServices.options(context, :coder)
    File.write!(ModelServices.path(s), "malformed private data must not reach reports")
    assert {:error, :model_service_authorization_unavailable} = ModelServices.options(context, :coder)
  end

  test "initial registry decode failures cannot expose secrets through configuration, polling or CLI", %{settings: s} do
    bind!(s)
    assert {:ok, saved} = ModelServices.save(ModelServices.path(s), s.model_services, 0, s.model_services)
    secret = "synthetic-malformed-registry-secret"

    for {malformed, reason} <- [
          {~s({"accidental_key":"#{secret}",), :invalid_model_services_json},
          {Jason.encode!(%{"accidental_key" => secret}), :invalid_model_services}
        ] do
      File.write!(ModelServices.path(s), malformed)

      assert {:error, ^reason} = ModelServices.load(ModelServices.path(s), saved)
      assert {:error, ^reason} = Config.settings()
      assert {:error, {:invalid_mvp_config, ^reason}} = SymphonyElixir.Config.validate!()
      assert {:error, ^reason} = ModelServices.read(s)
      assert {:error, ^reason} = ModelServices.save(ModelServices.path(s), saved, 1, saved)

      log =
        capture_log(fn ->
          # Exercise the actual polling callback synchronously, without starting a scheduler.
          assert {:noreply, state} = Orchestrator.handle_info(:run_poll_cycle, %Orchestrator.State{})
          Process.cancel_timer(state.tick_timer_ref)
          assert state.running == %{}
        end)

      assert log =~ "MVP dispatch disabled by invalid configuration: #{inspect(reason)}"
      refute log =~ secret
      refute log =~ malformed
      args = ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--preflight", s.workflow_path]
      assert {:error, report} = CLI.evaluate(args)
      assert report == "Preflight failed: #{inspect(reason)}"
      refute report =~ secret
      assert File.read!(ModelServices.path(s)) == malformed
      refute File.exists?(ModelServices.path(s) <> ".next")
      refute File.exists?(ModelServices.path(s) <> ".lock")
    end
  end

  test "retry reads successful WorkflowStore reload without replacing the original context", %{settings: s, root: root} do
    bind!(s)
    {:ok, s} = Config.settings()
    {:ok, selected} = Intake.resolve_comments([], s)
    parent = self()

    agent = fn _, _, _, opts ->
      send(parent, {:started, opts[:model_service]})
      revoked = put_in(s.model_services, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
      bind!(%{s | model_services: revoked})
      {:error, :turn_timeout}
    end

    context = attempt_context(root, s, selected, agent)
    assert {:error, :model_disabled} = Attempts.run(context, :coder, "retry", fn -> :ok end)
    assert_received {:started, service}
    assert service == selected.services["coder"]
    refute_received {:started, _}
  end

  test "unreadable, malformed, disabled or unbound workflow authorization fails closed", %{settings: s, root: root} do
    bind!(s)
    {:ok, s} = Config.settings()
    {:ok, selected} = Intake.resolve_comments([], s)
    context = attempt_context(root, s, selected)

    {:ok, workflow} = Workflow.load(s.workflow_path)
    File.write!(s.workflow_path, "---\n[invalid\n---")
    assert {:error, _} = WorkflowStore.force_reload()
    assert {:error, :model_service_authorization_unavailable} = ModelServices.options(context, :reviewer)

    for config <- [put_in(workflow.config, ["mvp", "enabled"], false), put_in(workflow.config, ["mvp", "enabled"], "yes"), put_in(workflow.config, ["mvp", "model_services", "presets"], [])] do
      File.write!(s.workflow_path, "---\n" <> Jason.encode!(config) <> "\n---\nfixture")
      assert :ok = WorkflowStore.force_reload()
      assert {:error, :model_service_authorization_unavailable} = ModelServices.options(context, :reviewer)
    end

    File.rm!(s.workflow_path)
    assert {:error, :model_service_authorization_unavailable} = ModelServices.options(context, :coder)
    context = update_in(context.settings, &Map.delete(&1, :workflow_path))
    assert {:error, :model_service_authorization_unavailable} = ModelServices.options(context, :coder)
  end

  test "legacy nondefault whitelist revocation reloads while execution remains frozen", %{settings: s, root: root} do
    s = %{s | model_services: nil, allowed_models: ["gpt-test", "gpt-other"]}
    bind!(s)
    {:ok, s} = Config.settings()
    models = %{coder: "gpt-other", reviewer: "gpt-test"}
    {:ok, services} = ModelServices.freeze(models, s, environment: fn _ -> nil end)
    context = %{settings: s, services: services, workspace: root, models: models}
    assert {:ok, options} = ModelServices.options(context, :diagnosis)
    assert options[:model_service] == services["coder"]
    bind!(%{s | allowed_models: ["gpt-test"]})
    assert {:error, :model_service_revoked} = ModelServices.options(context, :coder)
    assert {:error, :model_service_revoked} = ModelServices.options(context, :diagnosis)
    assert {:ok, options} = ModelServices.options(context, :reviewer)
    assert options[:model_service] == services["reviewer"]
  end

  defp bind!(s) do
    F.write_authority!(s)
    Workflow.set_workflow_file_path(s.workflow_path)
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _} = WorkflowStore.current()
  end

  defp alternate(s, role) do
    id = if role == :coder, do: "coding", else: "reviewing"
    registry = put_in(s.model_services, ["presets", "alternate"], s.model_services["presets"][id])
    {:ok, registry} = ModelCatalog.register(registry, "alternate", "gpt-test", ~w(medium high))
    {:ok, service} = ModelServices.snapshot(%{s | model_services: registry}, "alternate", role, "fixture")
    {:ok, registry} = ModelCatalog.attest(registry, service, F.proof(role))
    %{s | model_services: registry}
  end

  defp revoke(registry, service, :disable),
    do: {put_in(registry, ["catalog", service["id"], "models", service["model"], "disabled"], true), :model_disabled}

  defp revoke(registry, service, :remove_preset),
    do: {update_in(registry["presets"], &Map.delete(&1, service["id"])), :model_service_revoked}

  defp revoke(registry, service, :remove_evidence),
    do: {update_in(registry["validations"], &Map.delete(&1, ModelServices.binding(service))), :model_role_not_verified}

  defp revoke(registry, service, :expire_evidence),
    do: {put_in(registry, ["validations", ModelServices.binding(service), "expires_at"], "2000-01-01T00:00:00Z"), :model_validation_expired}

  defp attempt_context(root, settings, selected, agent \\ fn _, _, _, _ -> flunk("revoked model must not start") end) do
    directory = Path.join(root, "attempt-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    receipt = Path.join(directory, "receipt.json")
    {:ok, policy} = Recovery.settings(%{"enabled" => true})

    File.write!(
      receipt,
      Jason.encode!(%{
        "status" => "coding",
        "rounds" => [%{"evidence" => directory, "usage" => %{}}],
        "recovery" => %{"policy" => policy, "started_at" => DateTime.to_iso8601(DateTime.utc_now()), "agent_attempts" => 0, "events" => []}
      })
    )

    %{settings: Map.put(settings, :recovery, policy), services: selected.services, workspace: root, receipt: receipt, issue: %{}, limit: 0, opts: [agent: agent]}
  end
end
