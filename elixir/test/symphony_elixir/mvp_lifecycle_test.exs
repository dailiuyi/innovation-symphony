defmodule SymphonyElixir.Mvp.LifecycleTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureIO

  alias Mix.Tasks.Mvp.{Check, Reconcile, Release}
  alias SymphonyElixir.{AgentRunner, Config, Mvp, WorkflowStore, Workspace}
  alias SymphonyElixir.Mvp.{Commands, Receipt}
  alias SymphonyElixir.Tracker.Issue

  test "missing MVP config preserves upstream availability; explicit disable and receipt close intake" do
    issue = issue("GH-41")
    workflow_dir = Path.dirname(Workflow.workflow_file_path())

    write_github_workflow!(mvp: :omitted)
    assert {:ok, %{enabled: false, configured: false}} = Config.mvp_settings()
    assert Mvp.available?(issue)

    write_github_workflow!(mvp: %{"enabled" => false})
    assert {:ok, %{enabled: false, configured: true}} = Config.mvp_settings()
    refute Mvp.available?(issue)

    write_github_workflow!(mvp: valid_mvp(workflow_dir))
    assert {:ok, %{enabled: true, configured: true} = settings} = Config.mvp_settings()
    assert Mvp.available?(issue)

    assert {:ok, _receipt} = Receipt.claim(settings, issue)
    refute Mvp.available?(issue)
  end

  test "AgentRunner blocks an explicitly disabled queue without creating a workspace or starting a turn" do
    issue = issue("GH-42")
    write_github_workflow!(mvp: %{"enabled" => false})

    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:codex_worker_update, "GH-42", %{event: :turn_input_required, message: message}}
    assert message =~ "mvp_disabled"

    workspace = Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))
    refute File.exists?(workspace)
    refute_receive {:worker_runtime_info, "GH-42", _}
  end

  test "invalid MVP configuration blocks instead of entering the upstream runner" do
    issue = issue("GH-43")
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "invalid-config-before-run")

    write_github_workflow!(
      mvp: %{"enabled" => true, "coder_model" => "coder"},
      before_run: "printf should-not-run > #{marker}"
    )

    assert {:error, _reason} = Config.mvp_settings()
    refute Mvp.available?(issue)
    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:codex_worker_update, "GH-43", %{event: :turn_input_required}}
    refute File.exists?(marker)

    workspace = Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))
    refute File.exists?(workspace)
    refute_receive {:worker_runtime_info, "GH-43", _}
  end

  test "403 and 503 intake failures create blocked receipts before workspace creation" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    write_github_workflow!(mvp: valid_mvp(workflow_dir))
    assert {:ok, settings} = Config.mvp_settings()
    workspace_root = Config.local_workspace_root()

    for {number, status} <- [{44, 403}, {45, 503}] do
      current_issue = issue("GH-#{number}", number)

      request_fun = fn "GET", path, _params, nil, _github_settings ->
        send(self(), {:github_request, path, status})
        {:ok, %{status: status, body: %{"message" => "test response"}}}
      end

      assert :ok =
               Mvp.run(
                 current_issue,
                 self(),
                 settings,
                 request_fun: request_fun
               )

      receipt = Receipt.path(settings, current_issue)
      receipt_data = Receipt.read(receipt)
      assert receipt_data["status"] == "blocked"
      assert receipt_data["reason"] =~ Integer.to_string(status)
      events_path = "/repos/owner/repo/issues/#{number}/events"
      assert_receive {:github_request, ^events_path, ^status}

      workspace = Path.join(workspace_root, Workspace.workspace_key(current_issue))
      refute File.exists?(workspace)
    end
  end

  test "after_run hook runs after workspace creation even when before_run fails" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    marker = Path.join(workflow_dir, "after-run-marker")

    write_github_workflow!(
      mvp: valid_mvp(workflow_dir),
      before_run: "false",
      after_run: "printf after-run > #{marker}"
    )

    assert {:ok, settings} = Config.mvp_settings()

    request_fun = fn "GET", path, _params, nil, _github_settings ->
      body =
        if String.ends_with?(path, "/events") do
          [ready_event(1, "alice")]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    current_issue = issue("GH-46", 46)

    assert :ok =
             Mvp.run(
               current_issue,
               self(),
               settings,
               request_fun: request_fun
             )

    assert File.read!(marker) == "after-run"
    assert Receipt.read(Receipt.path(settings, current_issue))["status"] == "blocked"
  end

  test "release archives only pre-coding blocked receipts and makes the key retryable" do
    state_dir = unique_path("release-state")
    issue = issue("GH-47", 47)
    settings = %{state_dir: state_dir}
    on_exit(fn -> File.rm_rf(state_dir) end)

    assert {:ok, receipt} = Receipt.claim(settings, issue)
    assert :ok = Receipt.update(receipt, "blocked", %{"reason" => "temporary API failure"})

    capture_io(fn -> Release.run([receipt]) end)

    refute File.exists?(receipt)
    [archived] = Path.wildcard(receipt <> ".released-*")
    assert Receipt.read(archived)["status"] == "blocked"
    assert {:ok, retried_receipt} = Receipt.claim(settings, issue)
    assert retried_receipt == receipt
  end

  test "release refuses receipts with base, candidate, or publication state" do
    state_dir = unique_path("unreleasable-state")
    on_exit(fn -> File.rm_rf(state_dir) end)

    receipts = [
      {"blocked", %{"base_sha" => String.duplicate("a", 40)}},
      {"blocked", %{"candidate_sha" => String.duplicate("b", 40)}},
      {"publish_pending", %{"base_sha" => String.duplicate("c", 40), "candidate_sha" => String.duplicate("d", 40)}},
      {"awaiting_human", %{"base_sha" => String.duplicate("e", 40), "candidate_sha" => String.duplicate("f", 40)}}
    ]

    for {{status, fields}, number} <- Enum.zip(receipts, 48..51) do
      settings = %{state_dir: state_dir}
      current_issue = issue("GH-#{number}", number)
      assert {:ok, receipt} = Receipt.claim(settings, current_issue)
      assert :ok = Receipt.update(receipt, status, fields)

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/Not a pre-coding blocked receipt/, fn ->
          Release.run([receipt])
        end
      end)

      assert File.exists?(receipt)
      assert Path.wildcard(receipt <> ".released-*") == []
    end
  end

  test "maintenance commands validate current files without dispatching" do
    path = Workflow.workflow_file_path()
    write_github_workflow!(mvp: %{"enabled" => false})
    assert capture_io(fn -> Check.run([path]) end) =~ "enabled=false"
    assert_raise Mix.Error, fn -> Check.run([]) end
    assert_raise Mix.Error, fn -> Release.run([]) end
    assert_raise Mix.Error, fn -> Reconcile.run([]) end

    callback = fn receipt, options ->
      assert Path.type(receipt) == :absolute
      assert options[:tracker_settings].kind == "github"
      {:ok, "https://github.com/owner/repo/pull/1"}
    end

    assert capture_io(fn -> Reconcile.reconcile([path, "receipt.json"], callback) end) =~ "Matched:"

    assert_raise Mix.Error, ~r/Still unresolved/, fn ->
      Reconcile.reconcile([path, "receipt.json"], fn _, _ -> {:error, :uncertain} end)
    end

    assert_raise Mix.Error, ~r/Invalid local configuration/, fn -> Check.run([path <> ".missing"]) end
    assert_raise Mix.Error, ~r/Invalid workflow/, fn -> Reconcile.reconcile([path <> ".missing", "receipt.json"], callback) end
  end

  test "no ready label and invalid runtime cannot create a durable claim" do
    write_github_workflow!(mvp: valid_mvp(Path.dirname(Workflow.workflow_file_path())))
    {:ok, settings} = Config.mvp_settings()
    current = %{issue("60", 60) | labels: []}
    refute Mvp.available?(current)
    assert :ok = Mvp.run(current, nil, settings)
    refute Receipt.exists?(settings, current)

    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "max_concurrent_agents: 1", "max_concurrent_agents: 2"))
    WorkflowStore.force_reload()
    assert :ok = Mvp.run(issue("61", 61), nil, settings)
    refute Receipt.exists?(settings, issue("61", 61))
  end

  test "claimed tasks cannot reenter; execution exceptions preserve evidence and run cleanup" do
    root = Path.dirname(Workflow.workflow_file_path())
    marker = Path.join(root, "cleanup")
    write_github_workflow!(mvp: valid_mvp(root), after_run: "touch #{marker}")
    {:ok, settings} = Config.mvp_settings()
    current = issue("62", 62)

    assert :ok =
             Mvp.run(current, self(), settings,
               request_fun: &intake_success/5,
               repository: fn _, _ -> raise "repository test failure" end
             )

    assert File.exists?(marker)
    assert Receipt.read(Receipt.path(settings, current))["reason"] =~ "repository test failure"
    assert :ok = Mvp.run(current, self(), settings)
    assert_receive {:codex_worker_update, "62", %{message: ":mvp_receipt_exists"}}
  end

  test "complete local task relays coder events and waits for human merge" do
    root = Path.dirname(Workflow.workflow_file_path())
    origin = Path.join(root, "origin")
    File.mkdir_p!(origin)
    Commands.git!(["init", "-b", "main"], origin)
    File.write!(Path.join(origin, "base.txt"), "base")
    Commands.git!(["add", "."], origin)
    Commands.git!(["commit", "-m", "base"], origin)
    write_github_workflow!(mvp: valid_mvp(root), before_run: "git init")
    {:ok, settings} = Config.mvp_settings()
    current = issue("63", 63)

    agent = fn workspace, _, _, options ->
      options[:on_message].(%{event: :test_event, timestamp: DateTime.utc_now()})

      if options[:read_only] do
        {:ok, %{output_text: ~s({"approved":true,"summary":"reviewed"})}}
      else
        File.write!(Path.join(workspace, "change.txt"), "candidate")
        {:ok, %{}}
      end
    end

    assert :ok =
             Mvp.run(current, self(), settings,
               request_fun: &intake_success/5,
               repository: fn _, _ -> {:ok, %{repo: "owner/repo", base: "main", url: origin}} end,
               agent: agent,
               publish: fn _, _, _, _, _, file, _ ->
                 Receipt.update(file, "awaiting_human", %{"pull_request" => "https://example.test/pr/1"})
                 {:ok, "https://example.test/pr/1"}
               end
             )

    assert_receive {:codex_worker_update, "63", %{event: :test_event}}
    assert_receive {:codex_worker_update, "63", %{event: :turn_input_required, message: message}}
    assert message =~ "awaiting_human_merge"
    refute Mvp.available?(current)
  end

  test "external waits survive the worker lifecycle and remain unavailable for automatic intake" do
    root = Path.dirname(Workflow.workflow_file_path())
    origin = Path.join(root, "external-origin")
    File.mkdir_p!(origin)
    Commands.git!(["init", "-b", "main"], origin)
    File.write!(Path.join(origin, "base.txt"), "base")
    Commands.git!(["add", "."], origin)
    Commands.git!(["commit", "-m", "base"], origin)
    config = valid_mvp(root) |> Map.put("recovery", %{"enabled" => true})
    write_github_workflow!(mvp: config, before_run: "git init")
    {:ok, settings} = Config.mvp_settings()
    current = issue("64", 64)

    review = %{
      "approved" => false,
      "summary" => "Device evidence is missing",
      "criteria" => [%{"acceptance" => "real device", "tests" => [], "assertion_strength" => "unverified", "failure_sensitivity" => "unverified", "adequate" => false}],
      "blockers" => [
        %{"acceptance" => "real device", "kind" => "external_condition", "reason" => "device unavailable", "required_evidence" => "same candidate device log", "handoff" => "device operator"}
      ]
    }

    agent = fn workspace, _, _, options ->
      if options[:read_only] do
        send(self(), :external_reviewer)
        {:ok, %{output_text: Jason.encode!(review)}}
      else
        send(self(), :external_coder)
        File.write!(Path.join(workspace, "change.txt"), "candidate")
        {:ok, %{}}
      end
    end

    request = fn method, path, params, body, tracker ->
      if method == "POST" do
        {:ok, %{status: 201, body: %{"id" => 1, "html_url" => "https://example.test/comment/1", "body" => body["body"]}}}
      else
        intake_success(method, path, params, body, tracker)
      end
    end

    assert :ok =
             Mvp.run(current, self(), settings,
               request_fun: request,
               repository: fn _, _ -> {:ok, %{repo: "owner/repo", base: "main", url: origin}} end,
               agent: agent,
               publish: fn _, _, _, _, _, _, _ -> flunk("external wait cannot publish") end
             )

    data = Receipt.read(Receipt.path(settings, current))
    assert data["status"] == "awaiting_external"
    assert File.regular?(data["external_handoff"]["record_path"])
    assert_receive :external_coder
    assert_receive :external_reviewer
    refute_receive :external_coder
    refute_receive :external_reviewer
    assert_receive {:codex_worker_update, "64", %{event: :turn_input_required, message: message}}
    assert message =~ "mvp_awaiting_external"
    refute Mvp.available?(current)
  end

  defp intake_success("GET", path, _, nil, _) do
    body = if String.ends_with?(path, "/events"), do: [ready_event(1, "alice")], else: []
    {:ok, %{status: 200, body: body}}
  end

  defp valid_mvp(workflow_dir) do
    %{
      "enabled" => true,
      "coder_model" => "coder-model",
      "reviewer_model" => "reviewer-model",
      "allowed_models" => ["coder-model", "reviewer-model"],
      "allowed_actors" => ["alice"],
      "checks" => [["true"]],
      "state_dir" => Path.join(workflow_dir, "mvp-state")
    }
  end

  defp issue(identifier, number \\ 41) do
    %Issue{
      id: identifier,
      identifier: identifier,
      title: "Lifecycle test issue",
      description: "Exercise the bounded MVP lifecycle.",
      state: "open",
      labels: ["ready"],
      dispatchable: true,
      native_ref: %{"repo" => "owner/repo", "number" => number}
    }
  end

  defp ready_event(id, login) do
    %{
      "id" => id,
      "event" => "labeled",
      "label" => %{"name" => "ready"},
      "actor" => %{"login" => login}
    }
  end

  defp unique_path(name) do
    Path.join(System.tmp_dir!(), "symphony-mvp-#{name}-#{System.unique_integer([:positive])}")
  end

  defp write_github_workflow!(opts) do
    workflow_path = Workflow.workflow_file_path()
    workspace_root = Keyword.get(opts, :workspace_root, unique_path("workspace"))
    mvp_config = Keyword.get(opts, :mvp, :omitted)
    before_run = Keyword.get(opts, :before_run)
    after_run = Keyword.get(opts, :after_run)

    mvp_section =
      case mvp_config do
        :omitted ->
          []

        config when is_map(config) ->
          ["mvp:" | Enum.map(config, fn {key, value} -> "  #{key}: #{yaml_value(value)}" end)]
      end

    hooks =
      [
        if(before_run, do: "  before_run: #{yaml_value(before_run)}"),
        if(after_run, do: "  after_run: #{yaml_value(after_run)}")
      ]
      |> Enum.reject(&is_nil/1)

    hook_section = if hooks == [], do: [], else: ["hooks:" | hooks]

    workflow =
      [
        "---",
        "tracker:",
        "  kind: github",
        "  provider:",
        "    repo: \"owner/repo\"",
        "    token: \"test-token\"",
        "  required_labels: [\"ready\"]",
        "  active_states: [\"open\"]",
        "  terminal_states: [\"closed\"]",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "agent:",
        "  max_concurrent_agents: 1",
        "worker:",
        "  ssh_hosts: []",
        "codex:",
        "  command: \"codex app-server\"",
        "  approval_policy:",
        "    reject:",
        "      sandbox_approval: true",
        "      rules: true",
        "      mcp_elicitations: true",
        "  thread_sandbox: workspace-write",
        "  turn_sandbox_policy: null",
        mvp_section,
        hook_section,
        "---",
        "Lifecycle test prompt."
      ]
      |> List.flatten()
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.write!(workflow_path, workflow)
    assert :ok = WorkflowStore.force_reload()
    on_exit(fn -> File.rm_rf(workspace_root) end)
  end

  defp yaml_value(value), do: Jason.encode!(value)
end
