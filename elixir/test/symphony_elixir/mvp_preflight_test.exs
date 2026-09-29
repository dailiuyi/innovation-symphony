defmodule SymphonyElixir.Mvp.PreflightTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.Preflight
  alias SymphonyElixir.Workflow

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "WORKFLOW.md")}
  end

  test "ready issues are read through GET pagination without changing state, evidence or the runtime workflow", ctx do
    write_workflow(ctx)
    File.mkdir_p!(Path.join(ctx.root, "state/evidence"))
    File.write!(Path.join(ctx.root, "state/receipt.json"), ~s({"status":"awaiting_human"}))
    File.write!(Path.join(ctx.root, "state/evidence/keep"), "existing evidence")
    before = files(ctx.root)
    runtime_workflow = Workflow.workflow_file_path()
    runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    request = fn "GET", "/repos/owner/repo/issues", params, nil, settings ->
      assert settings.repo == "owner/repo"
      assert params["state"] == "open"
      send(self(), {:page, params["page"]})
      body = if params["page"] == 1, do: Enum.map(1..100, &issue/1), else: [issue(101)]
      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, %{mode: "preflight", status: "passed", issue_count: 101}} = probe(ctx.path, request)
    assert_received {:page, 1}
    assert_received {:page, 2}
    assert files(ctx.root) == before
    assert Workflow.workflow_file_path() == runtime_workflow
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == runtime
  end

  test "an empty remote queue passes, while HTTP, transport and payload failures fail", ctx do
    write_workflow(ctx)

    for {response, result} <- [
          {{:ok, %{status: 200, body: []}}, {:ok, %{mode: "preflight", status: "passed", issue_count: 0}}},
          {{:ok, %{status: 403, body: %{}}}, {:error, {:github_api_status, 403}}},
          {{:ok, %{status: 503, body: %{}}}, {:error, {:github_api_status, 503}}},
          {{:error, :timeout}, {:error, :timeout}},
          {{:ok, %{status: 200, body: %{}}}, {:error, :github_unknown_payload}}
        ] do
      assert probe(ctx.path, fn "GET", _, _, nil, _ -> response end) == result
    end

    refute File.exists?(Path.join(ctx.root, "state"))
    refute File.exists?(Path.join(ctx.root, "workspaces"))
  end

  test "invalid or disabled configurations fail before any remote call", ctx do
    never_fetch = fn _, _ -> flunk("invalid configuration must not contact GitHub") end

    assert {:error, {:missing_workflow_file, _, _}} = Preflight.run(ctx.path, fetch_issues: never_fetch)
    File.write!(ctx.path, "---\n[invalid\n---\n")
    assert {:error, _} = Preflight.run(ctx.path, fetch_issues: never_fetch)

    for {overrides, reason} <- [
          {%{"mvp" => %{"enabled" => false}}, :mvp_preflight_requires_enabled_workflow},
          {%{"mvp" => %{"coder_model" => nil}}, {:missing_mvp_setting, :coder_model}},
          {%{"agent" => %{"max_concurrent_agents" => 2}}, :mvp_requires_github_serial_local_linux_and_default_sandbox},
          {%{"tracker" => %{"active_states" => []}}, :mvp_preflight_requires_active_states},
          {%{"tracker" => %{"provider" => %{"repo" => "invalid"}}}, :invalid_github_repo},
          {%{"mvp" => %{"state_dir" => Path.join(ctx.root, "workspaces/state")}}, :mvp_state_workspace_overlap}
        ] do
      write_workflow(ctx, overrides)
      assert Preflight.run(ctx.path, fetch_issues: never_fetch) == {:error, reason}
    end
  end

  test "the default entry point rejects disabled workflows and empty polling states without changing files or runtime", ctx do
    runtime_workflow = Workflow.workflow_file_path()
    runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    for {overrides, reason} <- [
          {%{"mvp" => %{"enabled" => false}}, :mvp_preflight_requires_enabled_workflow},
          {%{"tracker" => %{"active_states" => []}}, :mvp_preflight_requires_active_states}
        ] do
      write_workflow(ctx, overrides)
      before = files(ctx.root)

      assert Preflight.run(ctx.path) == {:error, reason}
      assert files(ctx.root) == before
      assert Workflow.workflow_file_path() == runtime_workflow
      assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == runtime
    end
  end

  test "the CLI preflight path works in a fresh VM without a scheduler, task supervisor or workflow store", ctx do
    write_workflow(ctx)

    code = """
    alias SymphonyElixir.{CLI, Workflow, WorkflowStore, AgentRuntimeSupervisor, TaskSupervisor, Orchestrator}
    alias SymphonyElixir.Mvp.Preflight
    alias SymphonyElixir.GitHub.Client
    original_path = Workflow.workflow_file_path()
    deps = %{preflight: fn path ->
      Preflight.run(path, fetch_issues: fn states, tracker ->
        Client.fetch_issues_by_states(states, tracker, fn "GET", _, _, nil, _ ->
          {:ok, %{status: 200, body: [%{"number" => 3, "title" => "ready", "state" => "open", "labels" => [%{"name" => "ready"}]}]}}
        end)
      end)
    end}
    {:ok, %{issue_count: 1}} = CLI.evaluate([
      "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
      "--preflight", hd(System.argv())
    ], deps)
    for name <- [WorkflowStore, AgentRuntimeSupervisor, TaskSupervisor, Orchestrator] do
      nil = Process.whereis(name)
    end
    true = Workflow.workflow_file_path() == original_path
    IO.puts("read-only preflight passed")
    """

    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    before = files(ctx.root)
    {output, status} = System.cmd("elixir", code_paths ++ ["-e", code, ctx.path], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "read-only preflight passed"
    assert files(ctx.root) == before
  end

  defp probe(path, request) do
    Preflight.run(path, fetch_issues: fn states, tracker -> Client.fetch_issues_by_states(states, tracker, request) end)
  end

  defp issue(number) do
    %{"number" => number, "title" => "Ready task", "state" => "open", "labels" => [%{"name" => "ready"}]}
  end

  defp files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path -> {Path.relative_to(path, root), if(File.regular?(path), do: File.read!(path), else: :directory)} end)
  end

  defp write_workflow(ctx, overrides \\ %{}) do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "provider" => %{"repo" => "owner/repo", "token" => "test-token"},
        "active_states" => ["open"],
        "terminal_states" => ["closed"],
        "required_labels" => ["ready"]
      },
      "workspace" => %{"root" => Path.join(ctx.root, "workspaces")},
      "hooks" => %{"after_create" => "exit 99", "before_run" => "exit 99"},
      "agent" => %{"max_concurrent_agents" => 1},
      "codex" => %{"command" => "exit 99"},
      "mvp" => %{
        "enabled" => true,
        "coder_model" => "coder",
        "reviewer_model" => "reviewer",
        "allowed_models" => ["coder", "reviewer"],
        "allowed_actors" => ["alice"],
        "checks" => [["false"]],
        "state_dir" => Path.join(ctx.root, "state")
      }
    }

    File.write!(ctx.path, "---\n#{Jason.encode!(deep_merge(config, overrides))}\n---\nTest workflow\n")
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _, a, b when is_map(a) and is_map(b) -> deep_merge(a, b)
      _, _, b -> b
    end)
  end
end
