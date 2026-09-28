defmodule SymphonyElixir.Mvp.IntakeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.Intake
  alias SymphonyElixir.Tracker.Issue

  test "MVP settings default to disabled" do
    assert {:ok, settings} = MvpConfig.settings()
    refute settings.enabled
    assert settings.ready_label == "ready"
    assert settings.check_timeout_ms == 300_000
  end

  test "enabled settings validate defaults, argv checks, and resolve state path from workflow" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    state_dir = Path.join(workflow_dir, ".mvp-state-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(workflow_dir, "other-workspaces")

    write_mvp_workflow!(
      %{
        "enabled" => true,
        "coder_model" => "coder-a",
        "reviewer_model" => "reviewer-a",
        "allowed_models" => ["coder-a", "reviewer-a"],
        "allowed_actors" => ["alice"],
        "checks" => [["mix", "test"], ["mix", "lint"]],
        "state_dir" => Path.relative_to(state_dir, workflow_dir),
        "check_timeout_ms" => 120_000,
        "max_rework" => 0
      },
      workspace_root
    )

    assert {:ok, settings} = MvpConfig.settings()
    assert settings.enabled
    assert settings.coder_model == "coder-a"
    assert settings.reviewer_model == "reviewer-a"
    assert settings.checks == [["mix", "test"], ["mix", "lint"]]
    assert settings.state_dir == Path.expand(state_dir)
    assert settings.check_timeout_ms == 120_000
    assert settings.max_rework == 0
  end

  test "enabled settings reject missing or unsafe required values" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(workflow_dir, "workspace")

    write_mvp_workflow!(%{"enabled" => true, "coder_model" => "coder-a"}, workspace_root)
    assert {:error, {:missing_mvp_setting, :reviewer_model}} = MvpConfig.settings()

    write_mvp_workflow!(
      %{
        "enabled" => true,
        "coder_model" => "coder-a",
        "reviewer_model" => "reviewer-a",
        "allowed_models" => ["coder-a", "reviewer-a"],
        "allowed_actors" => ["alice"],
        "checks" => [["sh", "-c", "echo unsafe"]],
        "state_dir" => ".mvp-state"
      },
      workspace_root
    )

    assert {:error, :invalid_mvp_checks} = MvpConfig.settings()
  end

  test "state directory cannot overlap the workspace root or source tree" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(workflow_dir, "shared-workspace")
    state_dir = Path.join(workspace_root, "state")

    write_mvp_workflow!(valid_mvp_config(state_dir), workspace_root)
    assert {:error, :mvp_state_workspace_overlap} = MvpConfig.settings()

    source_root = Path.expand("../../../", __DIR__)

    write_mvp_workflow!(
      valid_mvp_config(Path.join(source_root, ".mvp-state-#{System.unique_integer([:positive])}")),
      Path.join(workflow_dir, "safe-workspace")
    )

    assert {:error, :mvp_state_source_overlap} = MvpConfig.settings()
  end

  test "workspace root cannot contain the source tree" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    source_root = Path.expand("../../../", __DIR__)
    state_dir = Path.join(workflow_dir, "safe-state")

    write_mvp_workflow!(valid_mvp_config(state_dir), source_root)
    assert {:error, :mvp_workspace_source_overlap} = MvpConfig.settings()
  end

  test "resolve_comments applies per-role overrides in comment ID order" do
    comments = [
      comment(20, "alice", "/symphony models coder=coder-b"),
      comment(2, "alice", "/symphony models reviewer=reviewer-b"),
      comment(1, "alice", "/symphony models coder=coder-a reviewer=reviewer-a"),
      comment(3, "bob", "/symphony models coder=invalid reviewer=invalid"),
      comment(4, "alice[bot]", "/symphony models coder=invalid"),
      comment(5, "alice", "I saw /symphony models coder=invalid in a discussion.")
    ]

    assert {:ok, %{coder: "coder-b", reviewer: "reviewer-b"}} =
             Intake.resolve_comments(comments, settings())
  end

  test "authorized malformed, duplicate, and disallowed model commands fail closed" do
    assert {:error, {:duplicate_model_role, :coder, 7}} =
             Intake.resolve_comments(
               [comment(7, "alice", "/symphony models coder=coder-a coder=coder-b")],
               settings()
             )

    assert {:error, {:model_not_allowed, "outside"}} =
             Intake.resolve_comments(
               [comment(8, "alice", "/symphony models coder=outside")],
               settings()
             )

    assert {:error, {:malformed_model_command, 9}} =
             Intake.resolve_comments(
               [comment(9, "alice", "/symphony models coder=")],
               settings()
             )
  end

  test "resolve paginates GitHub events and comments through the existing client" do
    issue = ready_issue()

    page_one_events =
      Enum.map(1..100, fn id ->
        if id == 9 do
          ready_event(id, "alice")
        else
          %{"id" => id, "event" => "closed"}
        end
      end)

    page_one_comments = Enum.map(1..100, &comment(&1, "bob", "ordinary discussion"))

    request_fun = fn "GET", path, params, nil, _github_settings ->
      send(self(), {:github_page, path, params["page"]})

      body =
        case {String.ends_with?(path, "/events"), params["page"]} do
          {true, 1} -> page_one_events
          {true, 2} -> [ready_event(101, "alice")]
          {false, 1} -> page_one_comments
          {false, 2} -> [comment(101, "alice", "/symphony models reviewer=reviewer-b")]
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, %{coder: "coder-a", reviewer: "reviewer-b"}} =
             Intake.resolve(issue, settings(), request_fun: request_fun, tracker_settings: github_tracker_settings())

    assert_receive {:github_page, "/repos/owner/repo/issues/12/events", 1}
    assert_receive {:github_page, "/repos/owner/repo/issues/12/events", 2}
    assert_receive {:github_page, "/repos/owner/repo/issues/12/comments", 1}
    assert_receive {:github_page, "/repos/owner/repo/issues/12/comments", 2}
  end

  test "latest ready label actor must be authorized" do
    request_fun = fn "GET", path, _params, nil, _github_settings ->
      body =
        if String.ends_with?(path, "/events") do
          [ready_event(5, "mallory")]
        else
          flunk("comments must not be read after an unauthorized ready event")
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:error, {:unauthorized_ready_actor, "mallory"}} =
             Intake.resolve(
               ready_issue(),
               settings(),
               request_fun: request_fun,
               tracker_settings: github_tracker_settings()
             )
  end

  test "public ready predicate is case insensitive for issue labels and ready events" do
    issue = %{state: "open", labels: [%{name: "READY"}], repo: "owner/repo", number: 12}
    assert Intake.ready?(issue, "ready")
    refute Intake.ready?(%{issue | labels: [%{"name" => "blocked"}]}, "ready")
    refute Intake.ready?(%{issue | state: "closed"}, "ready")
    refute Intake.ready?(issue, nil)

    request_fun = fn "GET", path, _params, nil, _github_settings ->
      body =
        if String.ends_with?(path, "/events") do
          [%{"id" => "5", "event" => "labeled", "label" => %{"name" => "ReAdY"}, "actor" => %{"login" => "alice"}}]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, %{coder: "coder-a", reviewer: "reviewer-a"}} =
             Intake.resolve(issue, settings(), request_fun: request_fun, tracker_settings: github_tracker_settings())
  end

  test "intake rejects disabled, malformed, unready, and invalid-reference requests before GitHub" do
    assert {:error, :mvp_disabled} = Intake.resolve(ready_issue(), %{enabled: false})
    assert {:error, :invalid_mvp_settings} = Intake.resolve(ready_issue(), %{})
    assert {:error, :invalid_mvp_settings} = Intake.resolve(ready_issue(), :bad_settings, [])
    assert {:error, :invalid_comments} = Intake.resolve_comments(:not_a_comment_list, settings())
    assert {:error, :invalid_mvp_settings} = Intake.resolve_comments([], %{})

    assert {:error, :invalid_mvp_default_model} =
             Intake.resolve_comments([], Map.put(settings(), :coder_model, :not_a_model))

    assert {:error, :invalid_mvp_settings} =
             Intake.resolve_comments([], Map.put(settings(), :allowed_actors, ["alice", "alice"]))

    assert {:error, :invalid_mvp_settings} =
             Intake.resolve_comments([], Map.put(settings(), :allowed_models, [" "]))

    for current_issue <- [
          :not_an_issue,
          %{"repo" => "owner/", "number" => 12},
          %{"repo" => 123, "number" => 12},
          %{"repo" => "owner/repo", "number" => "12x"},
          %{"repo" => "owner/repo", "number" => 0},
          %{"repo" => "owner/repo", "number" => 12, "state" => "closed", "labels" => ["ready"]},
          %{"repo" => "owner/repo", "number" => 12, "state" => "open", "labels" => ["other"]}
        ] do
      assert {:error, reason} = Intake.resolve(current_issue, settings())
      assert reason in [:invalid_issue_reference, :issue_not_ready]
    end
  end

  test "issue reference variants encode repository segments and accept ready labels" do
    issue_variants = [
      %{repo: "owner/repo name", number: "12", state: "open", labels: ["READY"]},
      %{"repository" => %{"full_name" => "owner/repo"}, "number" => 12, "state" => "open", "labels" => [%{"name" => "Ready"}]},
      %{repository: %{full_name: "owner/repo"}, number: "12", state: "open", labels: [%{name: "ready"}]}
    ]

    request_fun = fn "GET", path, _params, nil, _github_settings ->
      assert String.contains?(path, "/repos/owner/repo")

      body =
        if String.ends_with?(path, "/events") do
          [ready_event("5", "alice")]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    for issue <- issue_variants do
      assert {:ok, %{coder: "coder-a", reviewer: "reviewer-a"}} =
               Intake.resolve(issue, settings(), request_fun: request_fun, tracker_settings: github_tracker_settings())
    end

    encoded_request = fn "GET", path, _params, nil, _github_settings ->
      send(self(), {:requested_path, path})
      {:ok, %{status: 200, body: if(String.ends_with?(path, "/events"), do: [ready_event(1, "alice")], else: [])}}
    end

    assert {:ok, _} =
             Intake.resolve(
               %{repo: "owner/repo name", number: 12, state: "open", labels: ["ready"]},
               settings(),
               request_fun: encoded_request,
               tracker_settings: github_tracker_settings()
             )

    assert_receive {:requested_path, "/repos/owner/repo%20name/issues/12/events"}
  end

  test "GitHub intake propagates status and transport errors and rejects non-list payloads" do
    rate_limited = fn _, _, _, _, _ -> {:ok, %{status: 429, body: %{"message" => "rate limited"}}} end

    for {request_fun, expected} <- [
          {rate_limited, {:github_api_status, 429}},
          {fn _method, _path, _params, _body, _settings -> {:error, :timeout} end, :timeout},
          {fn _method, path, _params, _body, _settings ->
             {:ok, %{status: 200, body: if(String.ends_with?(path, "/events"), do: "not a list", else: [])}}
           end, :github_unknown_payload}
        ] do
      assert {:error, ^expected} =
               Intake.resolve(
                 ready_issue(),
                 settings(),
                 request_fun: request_fun,
                 tracker_settings: github_tracker_settings()
               )
    end

    comments_failure = fn _method, path, _params, _body, _settings ->
      if String.ends_with?(path, "/events") do
        {:ok, %{status: 200, body: [ready_event(1, "alice")]}}
      else
        {:ok, %{status: 403}}
      end
    end

    assert {:error, {:github_api_status, 403}} =
             Intake.resolve(
               ready_issue(),
               settings(),
               request_fun: comments_failure,
               tracker_settings: github_tracker_settings()
             )
  end

  test "ready-event absence and malformed actor fail closed" do
    for events <- [[], [%{"event" => "labeled", "label" => %{"name" => "ready"}}]] do
      request_fun = fn "GET", path, _params, nil, _github_settings ->
        {:ok, %{status: 200, body: if(String.ends_with?(path, "/events"), do: events, else: [])}}
      end

      assert {:error, :ready_label_event_not_found} =
               Intake.resolve(
                 ready_issue(),
                 settings(),
                 request_fun: request_fun,
                 tracker_settings: github_tracker_settings()
               )
    end
  end

  test "authorized comment parser fails closed on missing IDs and unknown roles" do
    assert {:error, {:missing_model_command_id, nil}} =
             Intake.resolve_comments([%{"user" => %{"login" => "alice"}, "body" => "/symphony models coder=coder-b"}], settings())

    assert {:error, {:missing_model_command_id, "invalid"}} =
             Intake.resolve_comments([comment("invalid", "alice", "/symphony models coder=coder-b")], settings())

    assert {:error, {:unknown_model_role, "review", 12}} =
             Intake.resolve_comments([comment(12, "alice", "/symphony models review=coder-b")], settings())

    assert {:error, {:malformed_model_command, 13}} =
             Intake.resolve_comments([comment(13, "alice", "/symphony models coder=coder-b  reviewer=reviewer-b")], settings())
  end

  test "comment filtering tolerates discussion metadata and invalid IDs" do
    comments = [
      %{"id" => -1, "user" => "not a user", "body" => "/symphony models coder=outside"},
      %{"id" => "bad", "user" => %{"login" => "alice", "type" => "Bot"}, "body" => "/symphony models coder=outside"},
      %{"id" => 2.5, "user" => %{"login" => "alice[bot]"}, "body" => "/symphony models coder=outside"},
      %{"id" => 5, "user" => %{"login" => "alice"}, "body" => nil},
      comment("4", "alice", "/symphony models coder=coder-b"),
      comment(0, "alice", "  this only mentions /symphony models coder=outside")
    ]

    assert {:ok, %{coder: "coder-b", reviewer: "reviewer-a"}} = Intake.resolve_comments(comments, settings())
  end

  test "invalid tracker settings are returned by the existing GitHub client" do
    assert {:error, :missing_github_repo} =
             Intake.resolve(
               ready_issue(),
               settings(),
               request_fun: fn _, _, _, _, _ -> flunk("invalid tracker must fail before transport") end,
               tracker_settings: %{provider: %{"token" => "test-token"}}
             )

    assert {:error, :missing_github_token} =
             Intake.resolve(
               ready_issue(),
               settings(),
               tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => " "}}
             )
  end

  test "malformed GitHub event IDs sort behind valid ready events" do
    request_fun = fn "GET", path, _params, nil, _github_settings ->
      body =
        if String.ends_with?(path, "/events") do
          [ready_event("not-a-number", "mallory"), ready_event("8", "alice")]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, %{coder: "coder-a", reviewer: "reviewer-a"}} =
             Intake.resolve(
               ready_issue(),
               settings(),
               request_fun: request_fun,
               tracker_settings: github_tracker_settings()
             )
  end

  test "runtime path boundary rejects an unavailable OTP application directory" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    write_mvp_workflow!(valid_mvp_config(Path.join(workflow_dir, "missing-app-state")), unique_path("missing-app-workspace"))
    assert {:ok, _settings} = MvpConfig.settings()

    app_dir = :code.lib_dir(:symphony_elixir)
    assert is_list(app_dir)

    original_path = :code.get_path()
    app_dir = Path.expand(List.to_string(app_dir))
    app_ebin = Path.expand(Path.join(app_dir, "ebin"))

    filtered_path =
      Enum.reject(original_path, fn entry ->
        expanded = Path.expand(List.to_string(entry))
        expanded in [app_dir, app_ebin]
      end)

    assert true = :code.set_path(filtered_path)

    try do
      assert {:error, :bad_name} = :code.lib_dir(:symphony_elixir)
      assert {:error, :mvp_runtime_path_unavailable} = MvpConfig.settings()
    after
      assert true = :code.set_path(original_path)
    end
  end

  test "MVP config reports meaningful errors for malformed and unsafe values" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    config_for = fn changes -> Map.merge(valid_mvp_config(unique_path("state")), changes) end

    cases = [
      {"non-map MVP block", "not-a-map", :invalid_mvp_config},
      {"unknown field", Map.put(config_for.(%{}), "surprise", true), {:unknown_mvp_config_fields, ["surprise"]}},
      {"nonboolean enabled", Map.put(config_for.(%{}), "enabled", "true"), :invalid_mvp_enabled},
      {"blank disabled label", %{"enabled" => false, "ready_label" => " "}, :invalid_mvp_ready_label},
      {"invalid disabled timeout", %{"enabled" => false, "check_timeout_ms" => 0}, :invalid_mvp_check_timeout_ms},
      {"blank coder", config_for.(%{"coder_model" => " "}), {:missing_mvp_setting, :coder_model}},
      {"model whitespace", config_for.(%{"reviewer_model" => "reviewer model"}), {:invalid_mvp_setting, :reviewer_model}},
      {"model non-string", config_for.(%{"coder_model" => 42}), {:missing_mvp_setting, :coder_model}},
      {"empty model allowlist", config_for.(%{"allowed_models" => []}), {:invalid_mvp_setting, :allowed_models}},
      {"duplicate model allowlist", config_for.(%{"allowed_models" => ["coder-a", "reviewer-a", "coder-a"]}), {:invalid_mvp_setting, :allowed_models}},
      {"whitespace model allowlist", config_for.(%{"allowed_models" => ["coder-a", "reviewer-a", "bad model"]}), {:invalid_mvp_setting, :allowed_models}},
      {"default outside allowlist", config_for.(%{"allowed_models" => ["elsewhere"]}), :mvp_default_model_not_allowed},
      {"empty actors", config_for.(%{"allowed_actors" => []}), {:invalid_mvp_setting, :allowed_actors}},
      {"duplicate actors", config_for.(%{"allowed_actors" => ["alice", "alice"]}), {:invalid_mvp_setting, :allowed_actors}},
      {"whitespace actor", config_for.(%{"allowed_actors" => ["alice smith"]}), {:invalid_mvp_setting, :allowed_actors}},
      {"empty checks", config_for.(%{"checks" => []}), :invalid_mvp_checks},
      {"empty argv", config_for.(%{"checks" => [[]]}), :invalid_mvp_checks},
      {"blank argv token", config_for.(%{"checks" => [["mix", " "]]}), :invalid_mvp_checks},
      {"shell command", config_for.(%{"checks" => [["/bin/BASH", "-c", "echo unsafe"]]}), :invalid_mvp_checks},
      {"newline argv token", config_for.(%{"checks" => [["mix", "test\nother"]]}), :invalid_mvp_checks},
      {"missing state path", Map.delete(config_for.(%{}), "state_dir"), {:missing_mvp_setting, :state_dir}},
      {"blank state path", config_for.(%{"state_dir" => "  "}), {:missing_mvp_setting, :state_dir}},
      {"invalid timeout", config_for.(%{"check_timeout_ms" => -1}), :invalid_mvp_check_timeout_ms},
      {"unsupported rework", config_for.(%{"max_rework" => 1}), :mvp_rework_not_supported},
      {"invalid ready label", config_for.(%{"ready_label" => 7}), :invalid_mvp_ready_label}
    ]

    for {name, config, expected} <- cases do
      workspace_root = unique_path("config-workspace")
      write_mvp_workflow!(config, workspace_root)
      assert {:error, ^expected} = MvpConfig.settings(), name
    end

    write_mvp_workflow!(valid_mvp_config(Path.join(workflow_dir, "safe-state")), unique_path("unlabeled-workspace"), [])
    assert {:error, :mvp_ready_label_not_required} = MvpConfig.settings()

    write_mvp_workflow!(
      Map.put(valid_mvp_config(Path.join(workflow_dir, "safe-state")), "ready_label", "different"),
      unique_path("wrong-label-workspace"),
      ["ready"]
    )

    assert {:error, :mvp_ready_label_not_required} = MvpConfig.settings()

    write_mvp_workflow!(valid_mvp_config("/dev/null/child"), unique_path("safe-workspace"))
    assert {:error, {:invalid_mvp_state_dir, {:path_canonicalize_failed, _, :enotdir}}} = MvpConfig.settings()

    write_mvp_workflow!(valid_mvp_config(Path.join(workflow_dir, "safe-state")), "/dev/null/child")
    assert {:error, {:invalid_workspace_root, {:path_canonicalize_failed, _, :enotdir}}} = MvpConfig.settings()
  end

  test "enabled config accepts a case-insensitive tracker-required ready label" do
    config = Map.put(valid_mvp_config(unique_path("ready-state")), "ready_label", "ReAdY")
    write_mvp_workflow!(config, unique_path("ready-workspace"), ["READY"])
    assert {:ok, %{ready_label: "ReAdY"}} = MvpConfig.settings()
  end

  test "workspace environment variables are resolved before path-overlap checks" do
    env_name = "SYMPHONY_MVP_TEST_WORKSPACE"
    previous = System.get_env(env_name)

    on_exit(fn ->
      if is_nil(previous), do: System.delete_env(env_name), else: System.put_env(env_name, previous)
    end)

    workspace_root = unique_path("env-workspace")
    System.put_env(env_name, workspace_root)

    write_mvp_workflow!(
      valid_mvp_config(Path.join(workspace_root, "state")),
      "$#{env_name}"
    )

    assert {:error, :mvp_state_workspace_overlap} = MvpConfig.settings()

    source_root = Path.expand("../../../", __DIR__)
    System.put_env(env_name, source_root)
    write_mvp_workflow!(valid_mvp_config(unique_path("env-source-state")), "$#{env_name}")
    assert {:error, :mvp_workspace_source_overlap} = MvpConfig.settings()
  end

  test "source aliases cannot hide a workspace or state directory inside the repository" do
    alias_path = unique_path("source-alias")
    File.ln_s!(Path.expand("../../../", __DIR__), alias_path)

    write_mvp_workflow!(valid_mvp_config(Path.join(alias_path, "scripts/state")), unique_path("alias-workspace"))
    assert {:error, :mvp_state_source_overlap} = MvpConfig.settings()

    write_mvp_workflow!(valid_mvp_config(unique_path("alias-state")), Path.join(alias_path, "scripts/workspaces"))
    assert {:error, :mvp_workspace_source_overlap} = MvpConfig.settings()
  end

  defp settings do
    %{
      enabled: true,
      coder_model: "coder-a",
      reviewer_model: "reviewer-a",
      allowed_models: ["coder-a", "coder-b", "reviewer-a", "reviewer-b"],
      allowed_actors: ["alice"],
      ready_label: "ready"
    }
  end

  defp unique_path(name) do
    Path.join(Path.dirname(Workflow.workflow_file_path()), "#{name}-#{System.unique_integer([:positive])}")
  end

  defp valid_mvp_config(state_dir) do
    %{
      "enabled" => true,
      "coder_model" => "coder-a",
      "reviewer_model" => "reviewer-a",
      "allowed_models" => ["coder-a", "reviewer-a"],
      "allowed_actors" => ["alice"],
      "checks" => [["mix", "test"]],
      "state_dir" => state_dir
    }
  end

  defp ready_issue do
    %Issue{
      id: "12",
      native_ref: %{"repo" => "owner/repo", "number" => 12},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }
  end

  defp comment(id, login, body) do
    %{"id" => id, "user" => %{"login" => login, "type" => if(String.ends_with?(login, "[bot]"), do: "Bot", else: "User")}, "body" => body}
  end

  defp ready_event(id, login) do
    %{"id" => id, "event" => "labeled", "label" => %{"name" => "ready"}, "actor" => %{"login" => login}}
  end

  defp github_tracker_settings do
    %{provider: %{"repo" => "owner/repo", "token" => "test-token"}}
  end

  defp write_mvp_workflow!(mvp, workspace_root, required_labels \\ ["ready"]) do
    mvp_yaml =
      case mvp do
        config when is_map(config) ->
          ["mvp:" | Enum.map(config, fn {key, value} -> "  #{key}: #{yaml_value(value)}" end)]
          |> Enum.join("\n")

        other ->
          "mvp: #{yaml_value(other)}"
      end

    workflow = """
    ---
    tracker:
      kind: linear
      endpoint: "https://api.linear.app/graphql"
      api_key: "token"
      project_slug: "project"
      required_labels: #{yaml_value(required_labels)}
    workspace:
      root: "#{workspace_root}"
    #{mvp_yaml}
    ---

    Test prompt.
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      WorkflowStore.force_reload()
    end
  end

  defp yaml_value(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_value(value) when is_boolean(value), do: to_string(value)
  defp yaml_value(value) when is_float(value), do: Float.to_string(value)
  defp yaml_value(nil), do: "null"

  defp yaml_value(value) when is_list(value) do
    Enum.map_join(value, ", ", fn item ->
      case item do
        nested when is_list(nested) -> "[" <> Enum.map_join(nested, ", ", &yaml_value/1) <> "]"
        other -> yaml_value(other)
      end
    end)
    |> then(&("[" <> &1 <> "]"))
  end
end
