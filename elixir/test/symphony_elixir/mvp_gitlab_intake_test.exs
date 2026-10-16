defmodule SymphonyElixir.Mvp.GitLabIntakeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitLab.Client
  alias SymphonyElixir.Mvp
  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Mvp.{Intake, Receipt}

  @tracker %{kind: "gitlab", provider: %{"project_path" => "company/team/luca", "api_url" => "https://forge.test/api/v4", "api_key" => "fixture-token"}}
  @settings %{
    enabled: true,
    ready_label: "ready",
    allowed_actors: ["alice"],
    allowed_models: ["coder", "reviewer", "alternate"],
    coder_model: "coder",
    reviewer_model: "reviewer"
  }

  test "nested project ready events and human notes select models using paginated GET only" do
    request = fn "GET", path, query, nil, _settings ->
      case path do
        "/projects/company%2Fteam%2Fluca/issues/42/resource_label_events" ->
          {:ok, %{status: 200, body: [event(1, "alice")]}}

        "/projects/company%2Fteam%2Fluca/issues/42/notes" ->
          body =
            if query["page"] == 1 do
              Enum.map(1..100, &note(&1, "alice", "ordinary discussion"))
            else
              [note(101, "outsider", "/symphony models coder=bad"), note(102, "alice", "/symphony models coder=alternate"), Map.put(note(103, "alice", "/symphony models coder=bad"), "system", true)]
            end

          send(self(), {:notes_page, query["page"]})
          {:ok, %{status: 200, body: body}}
      end
    end

    assert {:ok, %{coder: "alternate", reviewer: "reviewer"}} = resolve(request)
    assert_received {:notes_page, 1}
    assert_received {:notes_page, 2}
  end

  test "latest ready addition requires an allowed actor and a removal invalidates stale polling" do
    for {events, error} <- [
          {[event(1, "alice"), event(2, "outsider")], {:unauthorized_ready_actor, "outsider"}},
          {[event(1, "alice"), Map.put(event(2, "alice"), "action", "remove")], :ready_label_event_not_found},
          {[], :ready_label_event_not_found}
        ] do
      assert {:error, ^error} =
               resolve(fn "GET", path, _, nil, _ ->
                 assert String.ends_with?(path, "/resource_label_events")
                 {:ok, %{status: 200, body: events}}
               end)
    end
  end

  test "cross instance or repository references cannot authorize an intake" do
    request = fn _, _, _, _, _ -> flunk("must reject before network access") end
    issue = issue()

    for changed <- [
          Map.put(issue.native_ref, "api_url", "https://other.test/api/v4"),
          Map.put(issue.native_ref, "repo", "other/project")
        ] do
      assert {:error, :invalid_issue_reference} = resolve_issue(%{issue | native_ref: changed}, request)
    end

    assert {:error, :mvp_disabled} =
             Intake.resolve(issue, %{@settings | enabled: false}, tracker_settings: @tracker, request_fun: request)
  end

  test "the authorized project path is resolved from the configured reference only" do
    System.put_env("SYMPHONY_TEST_GITLAB_PROJECT", "company/team/luca")
    System.put_env("GITLAB_PROJECT_PATH", "company/team/luca")

    on_exit(fn ->
      System.delete_env("SYMPHONY_TEST_GITLAB_PROJECT")
      System.delete_env("GITLAB_PROJECT_PATH")
    end)

    request = fn "GET", path, _query, nil, _ ->
      body = if String.ends_with?(path, "/resource_label_events"), do: [event(1, "alice")], else: []
      {:ok, %{status: 200, body: body}}
    end

    for project <- ["company/team/luca", "$SYMPHONY_TEST_GITLAB_PROJECT", nil] do
      assert {:ok, %{coder: "coder", reviewer: "reviewer"}} = resolve_with(request, project)
    end

    System.delete_env("SYMPHONY_TEST_GITLAB_PROJECT")
    assert {:error, :invalid_issue_reference} = resolve_with(request, "$SYMPHONY_TEST_GITLAB_PROJECT")

    System.put_env("GITLAB_PROJECT_PATH", "company/team/other")
    assert {:error, :invalid_issue_reference} = resolve_with(request, nil)
  end

  test "a gitlab tracker requires an https api/v4 endpoint before any receipt work" do
    root = Path.join(System.tmp_dir!(), "gitlab-contract-url-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    config = %{
      "tracker" => %{
        "kind" => "gitlab",
        "provider" => @tracker.provider,
        "active_states" => ["opened"],
        "terminal_states" => ["closed"],
        "required_labels" => ["ready"]
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "agent" => %{"max_concurrent_agents" => 1},
      "mvp" => %{
        "enabled" => false,
        "coder_model" => "coder",
        "reviewer_model" => "reviewer",
        "allowed_models" => ["coder", "reviewer"],
        "allowed_actors" => ["alice"],
        "checks" => [["false"]],
        "state_dir" => Path.join(root, "state")
      }
    }

    assert {:ok, _settings} = MvpConfig.settings(%{config: config}, root)

    for api_url <- ["https://forge.test/other", "http://forge.test/api/v4"] do
      provider = Map.put(@tracker.provider, "api_url", api_url)

      assert {:error, :mvp_requires_gitlab_api_v4_url} =
               MvpConfig.settings(%{config: put_in(config, ["tracker", "provider"], provider)}, root)
    end
  end

  test "strict GitLab polling rejects malformed pages and does not write" do
    issues_path = "/projects/company%2Fteam%2Fluca/issues"

    for body <- [%{}, [nil], [%{"iid" => 42}], [raw_issue(), %{}]] do
      request = fn "GET", ^issues_path, _, nil, _ -> {:ok, %{status: 200, body: body}} end
      assert {:error, :gitlab_unknown_payload} = Client.fetch_issues_by_states_strict(["opened"], @tracker, request)
    end

    single = fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: [raw_issue()]}} end
    assert {:ok, [issue]} = Client.fetch_issues_by_states_strict(["opened"], @tracker, single)
    assert issue.native_ref["repo"] == "company/team/luca"
    assert issue.native_ref["project_id"] == 77
  end

  test "receipts separate GitLab instances and preserve GitHub legacy file identity" do
    root = Path.join(System.tmp_dir!(), "gitlab-receipts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    settings = %{state_dir: root}
    issue = issue()
    other = %{issue | native_ref: Map.put(issue.native_ref, "api_url", "https://other.test/api/v4")}
    refute Receipt.path(settings, issue) == Receipt.path(settings, other)
    assert {:ok, path} = Receipt.claim(settings, issue)
    assert {:error, :mvp_receipt_exists} = Receipt.claim(settings, issue)
    receipt = Receipt.read(path)
    assert receipt["tracker_kind"] == "gitlab"
    assert receipt["tracker_api_url"] == "https://forge.test/api/v4"
    assert receipt["issue_native_ref"] == issue.native_ref
    assert receipt["issue_identifier"] == "GL-42"
    github = %{issue | native_ref: %{"repo" => "owner/repo", "number" => 42}}
    legacy = :crypto.hash(:sha256, "owner/repo:42") |> Base.encode16(case: :lower)
    assert Receipt.path(settings, github) == Path.join(root, legacy <> ".json")
  end

  test "explicit missing token environment fails closed and custom CA must contain certificates" do
    tracker = put_in(@tracker, [:provider, "api_key"], "$SYMPHONY_TEST_GITLAB_MISSING_ENV_7908")
    assert {:error, :missing_gitlab_api_key} = Client.validate_settings(tracker)
    assert {:error, :invalid_gitlab_ca_file} = Client.validate_settings(put_in(@tracker, [:provider, "ca_file"], "/nonexistent/ca.pem"))
    tracker = put_in(@tracker, [:provider, "ca_file"], "/etc/ssl/certs/ca-certificates.crt")
    assert :ok = Client.validate_settings(tracker)

    assert {:ok, %{status: 200}} =
             Client.request("GET", "/user", %{}, nil,
               tracker_settings: tracker,
               request_fun: fn "GET", "/user", %{}, nil, settings ->
                 assert settings.ca_file == "/etc/ssl/certs/ca-certificates.crt"
                 {:ok, %{status: 200, body: %{}}}
               end
             )
  end

  test "GitLab execution contract scrubs configured tokens and keeps serial sandbox gates" do
    root = Path.join(System.tmp_dir!(), "gitlab-contract-#{System.unique_integer([:positive])}")

    config = %{
      "tracker" => %{
        "kind" => "gitlab",
        "provider" => Map.put(@tracker.provider, "api_key", "$LUCA_FIXTURE_TOKEN"),
        "active_states" => ["opened"],
        "terminal_states" => ["closed"],
        "required_labels" => ["ready"]
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "agent" => %{"max_concurrent_agents" => 1},
      "mvp" => %{
        "enabled" => false,
        "coder_model" => "coder",
        "reviewer_model" => "reviewer",
        "allowed_models" => ["coder", "reviewer"],
        "allowed_actors" => ["alice"],
        "checks" => [["false"]],
        "state_dir" => Path.join(root, "state")
      }
    }

    assert {:ok, settings} = MvpConfig.settings(%{config: config}, root)
    assert "LUCA_FIXTURE_TOKEN" in settings.secret_environment_names
    assert "GITLAB_PAT" in settings.secret_environment_names
    refute settings.enabled
    assert {:ok, runtime} = Schema.parse(config)
    assert :ok = Mvp.validate_runtime(runtime)
    assert {:error, _} = Mvp.validate_runtime(put_in(runtime.agent.max_concurrent_agents, 2))
    assert {:error, _} = Mvp.validate_runtime(put_in(runtime.worker.ssh_hosts, ["remote"]))
  end

  defp resolve(request), do: resolve_issue(issue(), request)
  defp resolve_issue(issue, request), do: Intake.resolve(issue, @settings, tracker_settings: @tracker, request_fun: request)

  defp resolve_with(request, project_path) do
    tracker = %{kind: "gitlab", provider: Map.put(@tracker.provider, "project_path", project_path)}
    Intake.resolve(issue(), @settings, tracker_settings: tracker, request_fun: request)
  end

  defp issue, do: Client.normalize_issue_for_test(raw_issue(), @tracker)

  defp raw_issue,
    do: %{"id" => 1042, "iid" => 42, "project_id" => 77, "title" => "Scoped fixture", "state" => "opened", "labels" => ["ready"], "web_url" => "https://forge.test/company/team/luca/-/issues/42"}

  defp event(id, actor), do: %{"id" => id, "action" => "add", "label" => %{"name" => "ready"}, "user" => %{"username" => actor}}
  defp note(id, actor, body), do: %{"id" => id, "author" => %{"username" => actor}, "body" => body, "system" => false}
end
