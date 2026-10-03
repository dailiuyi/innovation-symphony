defmodule SymphonyElixir.MvpExternalTaskTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Mvp.External
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-external-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture = make_fixture(root)
    %{root: root, fixture: fixture}
  end

  test "status is local, allowlisted and redacts sensitive receipt text", %{fixture: f} do
    secret = "ghp_" <> String.duplicate("S", 36)

    File.write!(
      f.receipt,
      Jason.encode!(%{
        "status" => "awaiting_external",
        "candidate_sha" => f.record["candidate_sha"],
        "reason" => "External check blocked; token=#{secret}",
        "external_handoff" =>
          Map.merge(f.record, %{
            "record_path" => f.record_path,
            "record_sha256" => f.record_digest,
            "authorization" => "never display this",
            "conditions" => f.record["conditions"],
            "git_metadata" => %{secret => "credential"}
          })
      })
    )

    supervisor = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    started_apps = Application.started_applications()
    assert {:ok, summary} = External.status(f.receipt)
    encoded = Jason.encode!(summary)

    assert summary["status"] == "awaiting_external"
    assert summary["candidate_sha"] == f.record["candidate_sha"]
    assert summary["external_conditions"] == [safe_condition()]
    refute String.contains?(encoded, secret)
    refute String.contains?(encoded, "never display this")
    refute String.contains?(encoded, "git_metadata")
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == supervisor
    assert Application.started_applications() == started_apps
  end

  test "malformed receipt and unbound request fail before remote reads", %{fixture: f} do
    File.write!(f.receipt, "{")
    assert {:error, :invalid_input_file} = External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("must not delegate") end, f))

    write_valid_receipt(f)
    write_request(f, String.duplicate("0", 64))

    opts = resume_opts(fn _, _, _ -> flunk("unbound request must stop before delegation") end, f)
    opts = Keyword.put(opts, :fetch_issue, fn _, _, _ -> flunk("unbound request must not read the tracker") end)
    assert {:error, :invalid_request_binding} = External.resume(f.workflow, f.receipt, f.request, opts)

    write_request(f, f.receipt_digest)
    {:ok, request_raw} = File.read(f.request)
    {:ok, request} = Jason.decode(request_raw)
    malformed_auth = Map.put(request["authorization"], "legacy_closures", "not-a-list")
    File.write!(f.request, Jason.encode!(Map.put(request, "authorization", malformed_auth)))

    assert {:error, :invalid_request_binding} =
             External.resume(f.workflow, f.receipt, f.request, opts)

    write_request(f, f.receipt_digest)
    {:ok, request_raw} = File.read(f.request)
    {:ok, request} = Jason.decode(request_raw)
    [evidence] = request["authorization"]["external_evidence"]
    invalid_evidence = Map.put(evidence, "path", Path.join(Path.dirname(f.receipt), "missing-evidence.json"))
    authorization = Map.put(request["authorization"], "external_evidence", [invalid_evidence])
    File.write!(f.request, Jason.encode!(Map.put(request, "authorization", authorization)))

    assert {:error, :invalid_external_evidence} =
             External.resume(f.workflow, f.receipt, f.request, opts)
  end

  test "changed issue scope, removed ready label and changed models are refused", %{fixture: f} do
    write_valid_receipt(f)

    changed_scope = %{f.issue | title: "Changed title"}

    assert {:error, :issue_scope_changed} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("scope mismatch must not delegate") end, f, issue: changed_scope))

    no_ready_label = %{f.issue | labels: []}

    assert {:error, :issue_not_ready} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("not-ready issue must not delegate") end, f, issue: no_ready_label))

    changed_models = fn _, _, _ -> {:ok, %{coder: "other-model", reviewer: "reviewer-model"}} end

    assert {:error, :current_models_changed} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("model mismatch must not delegate") end, f, resolve_models: changed_models))
  end

  test "valid bound request delegates the frozen context and preserves a pending result", %{fixture: f} do
    write_valid_receipt(f)
    parent = self()

    delegate = fn context, digest, authorization ->
      send(parent, {:delegated, context, digest, authorization})
      {:error, {:mvp_awaiting_external, "next-handoff"}}
    end

    assert {:error, {:mvp_awaiting_external, "next-handoff"}} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(delegate, f))

    assert_received {:delegated, context, digest, authorization}
    assert context.receipt == f.receipt
    assert context.issue == f.issue
    assert context.models == %{coder: "coder-model", reviewer: "reviewer-model"}

    assert context.metadata == %{
             ".git/config" => {:ok, "git config bytes"},
             ".git/info/attributes" => {:error, :enoent},
             ".git/info/exclude" => {:ok, "exclude bytes"}
           }

    assert digest == f.receipt_digest
    assert authorization["id"] == "operator-17"
    assert authorization["command"] == ["mix", "mvp.external", "resume"]
    assert authorization["legacy_closures"] == [%{"kind" => "operator_check_resume"}]
    refute_received {:published, _}
  end

  test "audited recovery extensions restore a cumulative wall budget above one day", %{fixture: f} do
    f = add_recovery_extensions(f, [86_400_000, 86_400_000])
    parent = self()

    delegate = fn context, _digest, _authorization ->
      send(parent, {:effective_recovery, context.settings.recovery})
      {:error, {:mvp_awaiting_external, "next-handoff"}}
    end

    assert {:error, {:mvp_awaiting_external, "next-handoff"}} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(delegate, f))

    assert_received {:effective_recovery, recovery}
    assert recovery.max_elapsed_ms == 7_200_000 + 2 * 86_400_000
  end

  test "recovery budget expansion without extension audits is refused", %{fixture: f} do
    event = %{"kind" => "operator_wall_budget_extension", "operation_id" => "missing-audit", "extension_ms" => 1}
    policy = Map.put(f.recovery["policy"], "max_elapsed_ms", 7_200_001)
    recovery = f.recovery |> Map.put("policy", policy) |> Map.put("events", [event])
    f = rewrite_frozen_recovery(f, recovery)

    assert {:error, :invalid_frozen_context} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("unaudited expansion must not delegate") end, f))
  end

  test "recovery budget expansion with a mismatched extension audit is refused", %{fixture: f} do
    f = add_recovery_extensions(f, [86_400_000])
    audit_path = Path.join([f.receipt <> ".evidence", "operator-rechecks", "wall-extension-1", "authorization.json"])
    {:ok, audit_raw} = File.read(audit_path)
    {:ok, audit} = Jason.decode(audit_raw)
    bad_effective = Map.put(audit["effective_recovery_policy"], "max_elapsed_ms", 7_200_000 + 86_400_001)
    File.write!(audit_path, Jason.encode!(Map.put(audit, "effective_recovery_policy", bad_effective)))

    assert {:error, :invalid_frozen_context} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("mismatched audit must not delegate") end, f))
  end

  test "malformed recovery policy and git metadata are refused before delegation", %{fixture: f} do
    bad_policy = Map.put(f.record, "recovery_policy", "not-a-policy")
    f = rewrite_handoff_record(f, bad_policy)

    assert {:error, :invalid_frozen_context} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("bad policy must not delegate") end, f))

    for bad_metadata <- [
          Map.put(f.record["git_metadata"], ".git/config", "not-base64!"),
          Map.put(f.record["git_metadata"], ".git/config", 17)
        ] do
      f = rewrite_handoff_record(f, Map.put(f.record, "git_metadata", bad_metadata))

      assert {:error, :invalid_handoff_record} =
               External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("bad metadata must not delegate") end, f))
    end
  end

  test "status rejects malformed files without echoing contents", %{fixture: f} do
    File.write!(f.receipt, ~s({"status":"awaiting_external","reason":"ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}))
    assert {:ok, %{"status" => "awaiting_external", "external_conditions" => []} = summary} = External.status(f.receipt)
    refute String.contains?(Jason.encode!(summary), "ghp_")

    File.write!(f.receipt, "not-json secret=hidden")
    assert {:error, :invalid_receipt} = External.status(f.receipt)
  end

  test "status replaces unknown and non-displayable fields with safe defaults", %{fixture: f} do
    File.write!(
      f.receipt,
      Jason.encode!(%{
        "status" => "private-status",
        "candidate_sha" => "not-a-sha",
        "reason" => 42,
        "external_handoff" => %{"conditions" => ["skip", %{"kind" => "private", "acceptance" => 9}]}
      })
    )

    assert {:ok, summary} = External.status(f.receipt)

    assert summary == %{
             "status" => "unknown",
             "candidate_sha" => nil,
             "reason" => nil,
             "external_conditions" => [
               %{
                 "acceptance" => nil,
                 "kind" => nil,
                 "reason" => nil,
                 "required_evidence" => nil,
                 "handoff" => nil
               }
             ]
           }
  end

  test "Mix status and usage commands print safe output and refuse bad paths", %{fixture: f} do
    output = capture_io(fn -> External.run(["status", f.receipt]) end)
    assert {:ok, %{"status" => "awaiting_external"}} = Jason.decode(output)

    assert_raise Mix.Error, ~r/Cannot read a valid local receipt/, fn ->
      External.run(["status", Path.join(f.root, "missing.json")])
    end

    assert_raise Mix.Error, ~r/Usage: mix mvp\.external/, fn -> External.run([]) end
    assert {:error, :invalid_receipt} = External.status(nil)
  end

  test "programmatic Mix resume prints the pending and submitted outcomes", %{fixture: f} do
    pending = fn _, _, _ -> {:error, {:mvp_awaiting_external, "next-handoff"}} end

    pending_output =
      capture_io(fn ->
        External.run(["resume", f.workflow, f.receipt, f.request], resume_opts(pending, f))
      end)

    assert {:ok, %{"status" => "awaiting_external"}} = Jason.decode(pending_output)

    submitted = fn _, _, _ -> {:ok, "https://github.com/owner/repo/pull/42"} end

    submitted_output =
      capture_io(fn ->
        External.run(["resume", f.workflow, f.receipt, f.request], resume_opts(submitted, f))
      end)

    assert {:ok,
            %{
              "status" => "submitted_for_human_review",
              "pull_request" => "https://github.com/owner/repo/pull/42"
            }} = Jason.decode(submitted_output)
  end

  test "Mix resume command fails closed on a missing workflow without network access", %{fixture: f} do
    error =
      assert_raise Mix.Error, fn ->
        External.run(["resume", Path.join(f.root, "missing-WORKFLOW.md"), f.receipt, f.request])
      end

    assert error.message =~ "External resume refused"
    refute error.message =~ "test-token"
  end

  test "resume rejects malformed workflow, disabled or invalid MVP config, and bad tracker config", %{fixture: f} do
    opts = [runtime_validator: fn _ -> :ok end]
    missing_workflow = Path.join(f.root, "absent.md")
    assert {:error, :invalid_workflow} = External.resume(missing_workflow, f.receipt, f.request, opts)
    assert {:error, :invalid_workflow} = External.resume(nil, f.receipt, f.request, opts)

    disabled = put_in(f.config, ["mvp", "enabled"], false)
    write_workflow(f.workflow, disabled)
    assert {:error, :mvp_disabled} = External.resume(f.workflow, f.receipt, f.request, opts)

    invalid_mvp = put_in(f.config, ["mvp", "reviewer_model"], nil)
    write_workflow(f.workflow, invalid_mvp)
    assert {:error, :invalid_mvp_settings} = External.resume(f.workflow, f.receipt, f.request, opts)

    invalid_tracker = put_in(f.config, ["tracker", "provider", "repo"], "invalid repo")
    write_workflow(f.workflow, invalid_tracker)
    assert {:error, :invalid_github_repo} = External.resume(f.workflow, f.receipt, f.request, opts)
  end

  test "resume reports runtime validator errors and normalizes unexpected values and exceptions", %{fixture: f} do
    assert {:error, :runtime_unavailable} =
             External.resume(f.workflow, f.receipt, f.request, runtime_validator: fn _ -> {:error, :runtime_unavailable} end)

    assert {:error, :invalid_external_resume} =
             External.resume(f.workflow, f.receipt, f.request, runtime_validator: fn _ -> :unexpected end)

    assert {:error, :invalid_external_resume} =
             External.resume(f.workflow, f.receipt, f.request, runtime_validator: fn _ -> raise "runtime probe failed" end)
  end

  test "resume rejects invalid request and authorization shapes before tracker reads", %{fixture: f} do
    write_valid_receipt(f)

    opts =
      resume_opts(fn _, _, _ -> flunk("invalid authorization must not delegate") end, f)
      |> Keyword.put(:fetch_issue, fn _, _, _ -> flunk("invalid authorization must not fetch an issue") end)

    File.write!(f.request, "[]")
    assert {:error, :invalid_input_file} = External.resume(f.workflow, f.receipt, f.request, opts)

    bad_authorizations = [
      %{"authorization" => ""},
      %{"id" => "bad id"},
      %{"runtime_version" => "short"},
      %{"command" => "mix mvp.external resume"},
      %{"command" => []},
      %{"diagnostic" => ""},
      %{"predecessor" => 17},
      %{"legacy_closures" => "not-a-list"},
      %{"external_evidence" => []}
    ]

    for override <- bad_authorizations do
      write_request(f, f.receipt_digest)
      {:ok, raw} = File.read(f.request)
      {:ok, request} = Jason.decode(raw)
      authorization = Map.merge(request["authorization"], override)
      File.write!(f.request, Jason.encode!(Map.put(request, "authorization", authorization)))

      assert {:error, :invalid_request_binding} = External.resume(f.workflow, f.receipt, f.request, opts)
    end

    write_request(f, f.receipt_digest)
    {:ok, raw} = File.read(f.request)
    {:ok, request} = Jason.decode(raw)
    File.write!(f.request, Jason.encode!(Map.put(request, "authorization", nil)))
    assert {:error, :invalid_request_binding} = External.resume(f.workflow, f.receipt, f.request, opts)
  end

  test "resume uses the GitHub by-ID client and an injected request fixture when no issue callback is supplied", %{fixture: f} do
    write_valid_receipt(f)
    parent = self()
    issue_json = github_issue(f.issue)

    request_fun = fn method, path, _params, _body, _settings ->
      send(parent, {:github_request, method, path})
      {:ok, %{status: 200, body: issue_json}}
    end

    delegate = fn _context, _digest, _authorization -> {:error, {:mvp_awaiting_external, "second-handoff"}} end

    opts =
      resume_opts(delegate, f)
      |> Keyword.delete(:fetch_issue)
      |> Keyword.put(:request_fun, request_fun)

    assert {:error, {:mvp_awaiting_external, "second-handoff"}} =
             External.resume(f.workflow, f.receipt, f.request, opts)

    assert_received {:github_request, "GET", "/repos/owner/repo/issues/12"}
  end

  test "resume's default GitHub issue lookup rejects a nonnumeric frozen issue id without a request", %{fixture: f} do
    scope = Map.put(f.record["issue_scope"], "id", "not-a-number")
    record = Map.merge(f.record, %{"issue_scope" => scope, "issue_id" => "not-a-number"})
    f = rewrite_handoff_record(f, record)
    opts = resume_opts(fn _, _, _ -> flunk("invalid issue id must not delegate") end, f) |> Keyword.delete(:fetch_issue)

    assert {:error, :issue_unavailable_or_changed} =
             External.resume(f.workflow, f.receipt, f.request, opts)
  end

  test "resume converts issue lookup and model resolver exceptions into bounded errors", %{fixture: f} do
    issue_error = fn _, _, _ -> raise "tracker fixture failed" end

    assert {:error, :issue_unavailable_or_changed} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> :ok end, f, fetch_issue: issue_error))

    model_error = fn _, _, _ -> raise "model comment fixture failed" end

    assert {:error, :current_models_unavailable} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> :ok end, f, resolve_models: model_error))

    assert {:error, :current_models_unavailable} =
             External.resume(
               f.workflow,
               f.receipt,
               f.request,
               resume_opts(fn _, _, _ -> :ok end, f, resolve_models: fn _, _, _ -> {:error, :missing} end)
             )
  end

  test "resume checks open state and tracker binding variants", %{fixture: f} do
    write_valid_receipt(f)
    closed_issue = %{f.issue | state: "closed"}

    assert {:error, :issue_not_open} =
             External.resume(f.workflow, f.receipt, f.request, resume_opts(fn _, _, _ -> flunk("closed issue must stop") end, f, issue: closed_issue))

    binding = tracker_settings(f.workflow)

    wrapped_opts =
      resume_opts(fn _, _, _ -> {:error, {:mvp_awaiting_external, "wrapped"}} end, f)
      |> Keyword.put(:tracker_binding, %{tracker_settings: binding})

    assert {:error, {:mvp_awaiting_external, "wrapped"}} = External.resume(f.workflow, f.receipt, f.request, wrapped_opts)

    invalid_binding = Keyword.put(wrapped_opts, :tracker_binding, "wrong-shape")
    assert {:error, :tracker_binding_failed} = External.resume(f.workflow, f.receipt, f.request, invalid_binding)

    mismatched_binding = Keyword.put(wrapped_opts, :tracker_binding, %{tracker_settings: %{kind: "memory"}})
    assert {:error, :tracker_binding_mismatch} = External.resume(f.workflow, f.receipt, f.request, mismatched_binding)
  end

  test "resume verifies matching and mismatched default tracker bindings without changing workflow configuration", %{root: root, fixture: f} do
    original = Application.fetch_env(:symphony_elixir, :workflow_file_path)
    store = Process.whereis(WorkflowStore)
    original_state = if store, do: :sys.get_state(store)

    on_exit(fn ->
      case original do
        {:ok, path} -> Application.put_env(:symphony_elixir, :workflow_file_path, path)
        :error -> Application.delete_env(:symphony_elixir, :workflow_file_path)
      end

      if store, do: :sys.replace_state(store, fn _ -> original_state end)
    end)

    # A live store can retain any previous test's last valid tracker. Its presence
    # alone does not imply a mismatch: establish both configurations explicitly.
    Workflow.set_workflow_file_path(f.workflow)
    store = store || start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.tracker == tracker_settings(f.workflow)

    parent = self()

    delegate = fn context, _, _ ->
      send(parent, {:bound_tracker, Keyword.fetch!(context.opts, :tracker_settings)})
      {:error, {:mvp_awaiting_external, "bound"}}
    end

    opts = resume_opts(delegate, f) |> Keyword.delete(:tracker_binding)
    assert {:error, {:mvp_awaiting_external, "bound"}} = External.resume(f.workflow, f.receipt, f.request, opts)
    assert_received {:bound_tracker, tracker}
    assert tracker == settings.tracker
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, f.workflow}
    assert Process.whereis(WorkflowStore) == store

    mismatched = Path.join(root, "MISMATCHED_WORKFLOW.md")
    SymphonyElixir.TestSupport.write_workflow_file!(mismatched, tracker_kind: "memory")
    Workflow.set_workflow_file_path(mismatched)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, mismatched_settings} = WorkflowStore.settings()
    assert mismatched_settings.tracker.kind == "memory"

    assert {:error, :tracker_binding_mismatch} = External.resume(f.workflow, f.receipt, f.request, opts)
    refute_received {:bound_tracker, _}

    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, mismatched}
    assert Process.whereis(WorkflowStore) == store
    assert {:ok, ^mismatched_settings} = WorkflowStore.settings()
  end

  test "resume reports missing request runtime and distinguishes malformed runtime results", %{fixture: f} do
    opts =
      resume_opts(fn _, _, _ -> flunk("runtime failure must stop before delegation") end, f)
      |> Keyword.put(:fetch_issue, fn _, _, _ -> flunk("runtime failure must stop before tracker") end)

    assert {:error, :request_runtime_unavailable} =
             External.resume(f.workflow, f.receipt, f.request, Keyword.put(opts, :ensure_request_runtime, fn -> {:error, :missing} end))

    assert {:error, :request_runtime_unavailable} =
             External.resume(f.workflow, f.receipt, f.request, Keyword.put(opts, :ensure_request_runtime, fn -> :unexpected end))
  end

  test "resume's default executor delegation safely rejects a fixture receipt", %{fixture: f} do
    opts = resume_opts(fn _, _, _ -> flunk("default executor must be selected") end, f) |> Keyword.delete(:resume_external)
    assert {:error, _reason} = External.resume(f.workflow, f.receipt, f.request, opts)
  end

  defp resume_opts(delegate, fixture, overrides \\ []) do
    issue = Keyword.get(overrides, :issue, fixture.issue)
    resolve_models = Keyword.get(overrides, :resolve_models, fn _, _, _ -> {:ok, %{coder: "coder-model", reviewer: "reviewer-model"}} end)

    base = [
      runtime_validator: fn _ -> :ok end,
      ensure_request_runtime: fn -> {:ok, []} end,
      tracker_binding: tracker_settings(fixture.workflow),
      fetch_issue: fn _, _, _ -> {:ok, [issue]} end,
      resolve_models: resolve_models,
      resume_external: delegate
    ]

    Keyword.merge(base, Keyword.delete(overrides, :issue))
  end

  defp make_fixture(root) do
    workflow = Path.join(root, "WORKFLOW.md")
    workspace = Path.join(root, "workspaces/GH-12")
    File.mkdir_p!(workspace)

    config = %{
      "tracker" => %{
        "kind" => "github",
        "provider" => %{"repo" => "owner/repo", "token" => "test-token"},
        "required_labels" => ["ready"],
        "active_states" => ["open"],
        "terminal_states" => ["closed"]
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "agent" => %{"max_concurrent_agents" => 1},
      "codex" => %{"command" => "codex app-server", "thread_sandbox" => "workspace-write"},
      "mvp" => %{
        "enabled" => true,
        "coder_model" => "coder-model",
        "reviewer_model" => "reviewer-model",
        "allowed_models" => ["coder-model", "reviewer-model"],
        "allowed_actors" => ["alice"],
        "checks" => [["python3", "-m", "pytest"]],
        "state_dir" => Path.join(root, "state"),
        "ready_label" => "ready",
        "recovery" => %{"enabled" => true}
      }
    }

    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nPrompt\n")
    {:ok, loaded_workflow} = Workflow.load(workflow)
    {:ok, settings} = MvpConfig.settings(loaded_workflow, root)
    recovery_started_at = "2026-09-30T00:00:00Z"

    recovery = %{
      "policy" => settings.recovery |> Jason.encode!() |> Jason.decode!(),
      "started_at" => recovery_started_at,
      "agent_attempts" => 1,
      "adopted_agent_attempts" => 1,
      "events" => [],
      "adopted_rework_count" => 0,
      "external_wait_ms" => 0
    }

    receipt = Path.join(root, "receipt.json")

    issue = %Issue{
      id: "12",
      native_ref: %{"id" => 1200, "node_id" => "I_kwDOissue12", "number" => 12, "repo" => "owner/repo"},
      identifier: "GH-12",
      title: "External check",
      description: "Wait for outside evidence",
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }

    scope = %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description
    }

    metadata = %{
      ".git/config" => Base.encode64("git config bytes"),
      ".git/info/attributes" => nil,
      ".git/info/exclude" => Base.encode64("exclude bytes")
    }

    record = %{
      "schema" => 1,
      "id" => "external-1790740000000-abcdefgh",
      "source" => "review",
      "round" => 1,
      "candidate_sha" => String.duplicate("a", 40),
      "base_sha" => String.duplicate("b", 40),
      "issue_scope" => scope,
      "issue_native_ref" => issue.native_ref,
      "issue_id" => "12",
      "workspace" => workspace,
      "branch" => "codex/symphony-test",
      "repository" => %{"repo" => "owner/repo", "base" => "main", "url" => "https://github.com/owner/repo.git"},
      "models" => %{"coder" => "coder-model", "reviewer" => "reviewer-model"},
      "max_rework" => settings.recovery.max_rework,
      "checks" => settings.checks,
      "recovery_policy" => settings.recovery |> Jason.encode!() |> Jason.decode!(),
      "recovery_state" => recovery,
      "usage" => %{},
      "rework_count" => 0,
      "recovery_started_at" => recovery_started_at,
      "execution_sandbox" => settings.sandbox |> Jason.encode!() |> Jason.decode!(),
      "git_metadata" => metadata,
      "baseline_sha256" => String.duplicate("c", 64),
      "workspace_sha256" => String.duplicate("d", 64),
      "source_digest" => String.duplicate("e", 64),
      "review_path" => Path.join([receipt <> ".evidence", "round-1", "review.json"]),
      "source_data" => external_review(),
      "source_raw" => Jason.encode!(external_review()),
      "prior_evidence_history" => [],
      "conditions" => [safe_condition()],
      "started_at" => "2026-09-30T01:00:00Z",
      "status" => "pending",
      "external_wait_ms" => 0
    }

    record_path = Path.join([receipt <> ".evidence", "external-handoffs", record["id"] <> ".json"])
    File.mkdir_p!(Path.dirname(record_path))
    File.mkdir_p!(Path.dirname(record["review_path"]))
    File.write!(record["review_path"], record["source_raw"])
    record = Map.put(record, "source_digest", digest(record["source_raw"]))
    record_raw = Jason.encode!(record)
    File.write!(record_path, record_raw)
    record_digest = digest(record_raw)

    f = %{
      root: root,
      workflow: workflow,
      config: config,
      receipt: receipt,
      request: Path.join(root, "REQUEST.json"),
      workspace: workspace,
      issue: issue,
      recovery: recovery,
      record: record,
      record_path: record_path,
      record_digest: record_digest
    }

    write_valid_receipt(f)
    {:ok, raw_receipt} = File.read(receipt)
    evidence = Path.join(root, "outside-evidence.json")
    evidence_raw = ~s({"source":"device","result":"passed"})
    File.write!(evidence, evidence_raw)
    f = Map.merge(f, %{receipt_digest: digest(raw_receipt), external_evidence_path: evidence, external_evidence_sha: digest(evidence_raw)})
    write_request(f, f.receipt_digest)
    f
  end

  defp write_valid_receipt(f) do
    handoff = Map.merge(f.record, %{"record_path" => f.record_path, "record_sha256" => f.record_digest})

    receipt = %{
      "status" => "awaiting_external",
      "candidate_sha" => f.record["candidate_sha"],
      "base_sha" => f.record["base_sha"],
      "workspace" => f.record["workspace"],
      "branch" => f.record["branch"],
      "max_rework" => f.record["max_rework"],
      "execution_sandbox" => f.record["execution_sandbox"],
      "repository" => "owner/repo",
      "started_at" => "2026-09-30T00:00:00Z",
      "issue" => "12",
      "issue_scope" => f.record["issue_scope"],
      "models" => f.record["models"],
      "usage" => f.record["usage"],
      "rework_count" => f.record["rework_count"],
      "recovery" => f.recovery,
      "external_evidence_history" => [],
      "reason" => nil,
      "external_handoff" => handoff
    }

    File.write!(f.receipt, Jason.encode!(receipt))
  end

  defp write_workflow(path, config) do
    File.write!(path, "---\n#{Jason.encode!(config)}\n---\nPrompt\n")
  end

  defp github_issue(issue) do
    %{
      "id" => issue.native_ref["id"],
      "node_id" => issue.native_ref["node_id"],
      "number" => issue.native_ref["number"],
      "title" => issue.title,
      "body" => issue.description,
      "state" => issue.state,
      "labels" => Enum.map(issue.labels, &%{"name" => &1})
    }
  end

  defp rewrite_handoff_record(f, record) do
    record_raw = Jason.encode!(record)
    File.write!(f.record_path, record_raw)
    f = %{f | record: record, record_digest: digest(record_raw)}
    write_valid_receipt(f)
    {:ok, receipt_raw} = File.read(f.receipt)
    f = Map.put(f, :receipt_digest, digest(receipt_raw))
    write_request(f, f.receipt_digest)
    f
  end

  defp write_request(f, receipt_digest) do
    auth = %{
      "id" => "operator-17",
      "authorization" => "authorized operator handoff",
      "runtime_version" => String.duplicate("f", 40),
      "command" => ["mix", "mvp.external", "resume"],
      "predecessor" => nil,
      "legacy_closures" => [%{"kind" => "operator_check_resume"}],
      "external_evidence" => [
        %{
          "acceptance" => "Device evidence",
          "path" => Map.get(f, :external_evidence_path, Path.join(Path.dirname(f.receipt), "outside-evidence.json")),
          "sha256" => Map.get(f, :external_evidence_sha, digest(~s({"source":"device","result":"passed"})))
        }
      ]
    }

    File.write!(f.request, Jason.encode!(%{"receipt_sha256" => receipt_digest, "authorization" => auth}))
  end

  defp add_recovery_extensions(f, extensions) do
    {policy, events} =
      extensions
      |> Enum.with_index(1)
      |> Enum.reduce({f.recovery["policy"], [%{"kind" => "recovery_diagnostic"}]}, fn {extension, index}, {prior, events} ->
        id = "wall-extension-#{index}"
        effective = Map.put(prior, "max_elapsed_ms", prior["max_elapsed_ms"] + extension)
        operation = Path.join([f.receipt <> ".evidence", "operator-rechecks", id])
        File.mkdir_p!(operation)

        audit = %{
          "id" => id,
          "wall_budget_extension_ms" => extension,
          "original_recovery_policy" => prior,
          "effective_recovery_policy" => effective
        }

        File.write!(Path.join(operation, "authorization.json"), Jason.encode!(audit))
        File.write!(Path.join(operation, "completion.json"), Jason.encode!(%{"id" => id}))
        event = %{"kind" => "operator_wall_budget_extension", "operation_id" => id, "extension_ms" => extension}
        {effective, events ++ [event]}
      end)

    recovery = f.recovery |> Map.put("policy", policy) |> Map.put("events", events)
    rewrite_frozen_recovery(f, recovery)
  end

  defp rewrite_frozen_recovery(f, recovery) do
    record =
      f.record
      |> Map.put("recovery_policy", recovery["policy"])
      |> Map.put("recovery_state", recovery)

    record_raw = Jason.encode!(record)
    File.write!(f.record_path, record_raw)
    f = %{f | record: record, record_digest: digest(record_raw), recovery: recovery}
    write_valid_receipt(f)
    {:ok, receipt_raw} = File.read(f.receipt)
    f = Map.put(f, :receipt_digest, digest(receipt_raw))
    write_request(f, f.receipt_digest)
    f
  end

  defp tracker_settings(workflow_path) do
    {:ok, workflow} = Workflow.load(workflow_path)
    {:ok, settings} = Schema.parse(workflow.config)
    settings.tracker
  end

  defp safe_condition do
    %{
      "acceptance" => "Device evidence",
      "kind" => "external_condition",
      "reason" => "A physical device is required",
      "required_evidence" => "Provide a device test result",
      "handoff" => "Operator provides bound evidence"
    }
  end

  defp external_review do
    %{
      "approved" => false,
      "summary" => "Waiting for device evidence",
      "criteria" => [
        %{
          "acceptance" => "Device evidence",
          "tests" => [],
          "assertion_strength" => "The evidence establishes the acceptance result",
          "failure_sensitivity" => "Missing evidence leaves this acceptance unverified",
          "adequate" => false
        }
      ],
      "blockers" => [safe_condition()]
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
