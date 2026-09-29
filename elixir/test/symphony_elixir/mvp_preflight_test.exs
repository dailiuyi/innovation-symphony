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
          {{:ok, %{status: 200, body: %{}}}, {:error, :github_unknown_payload}},
          {{:ok, %{status: 200, body: [%{}]}}, {:error, :github_unknown_payload}},
          {{:ok, %{status: 200, body: [issue(1), %{}]}}, {:error, :github_unknown_payload}},
          {{:ok, %{status: 200, body: [nil, "invalid"]}}, {:error, :github_unknown_payload}}
        ] do
      assert probe(ctx.path, fn "GET", _, _, nil, _ -> response end) == result
    end

    refute File.exists?(Path.join(ctx.root, "state"))
    refute File.exists?(Path.join(ctx.root, "workspaces"))
  end

  test "a later page failure rejects the entire probe instead of returning partial results", ctx do
    write_workflow(ctx)
    before = files(ctx.root)

    for {response, reason} <- [
          {{:ok, %{status: 403, body: %{}}}, {:github_api_status, 403}},
          {{:error, :timeout}, :timeout},
          {{:ok, %{status: 200, body: %{}}}, :github_unknown_payload},
          {{:ok, %{status: 200, body: [%{}]}}, :github_unknown_payload},
          {{:ok, %{status: 200, body: [issue(101), %{}]}}, :github_unknown_payload}
        ] do
      request = fn "GET", "/repos/owner/repo/issues", params, nil, _ ->
        send(self(), {:page, params["page"]})

        case params["page"] do
          1 -> {:ok, %{status: 200, body: Enum.map(1..100, &issue/1)}}
          2 -> response
        end
      end

      assert probe(ctx.path, request) == {:error, reason}
      assert_received {:page, 1}
      assert_received {:page, 2}
      refute_received {:page, 3}
      assert files(ctx.root) == before
    end
  end

  test "strict reads reject unknown states and malformed nested fields before filtering", ctx do
    write_workflow(ctx)
    before = files(ctx.root)

    for overrides <- [
          %{"state" => "bogus"},
          %{"state" => 1},
          %{"assignee" => "alice"},
          %{"assignee" => []},
          %{"assignee" => %{}},
          %{"assignee" => %{"login" => 1}},
          %{"labels" => %{}},
          %{"labels" => [nil]},
          %{"labels" => [%{"name" => 1}]}
        ] do
      malformed = Map.merge(issue(101), overrides)

      for body <- [[malformed], [issue(1), malformed]] do
        assert {:error, :github_unknown_payload} = probe(ctx.path, fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: body}} end)
      end

      # Even a known, unselected state must have a valid record shape.
      closed_malformed = Map.put(malformed, "state", "closed")

      unless Map.has_key?(overrides, "state") do
        assert {:error, :github_unknown_payload} =
                 probe(ctx.path, fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: [closed_malformed]}} end)
      end
    end

    for body <- [
          [Map.put(issue(1), "state", "closed")],
          [Map.merge(issue(1), %{"assignee" => %{"login" => "alice"}, "labels" => ["ready"]})]
        ] do
      count = if hd(body)["state"] == "closed", do: 0, else: 1
      assert {:ok, %{issue_count: ^count}} = probe(ctx.path, fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: body}} end)
    end

    assert files(ctx.root) == before
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

  test "nonempty states must select a GitHub request before preflight can pass", ctx do
    never_fetch = fn _, _ -> flunk("invalid polling states must not contact GitHub") end

    for states <- [["ready"], ["all"], [" "], ["todo", "review"], ["Closed"], ["open", "closed"], ["open", "ready"]] do
      write_workflow(ctx, %{"tracker" => %{"active_states" => states}})
      before = files(ctx.root)

      assert {:error, :invalid_github_states} = Preflight.run(ctx.path, fetch_issues: never_fetch)
      assert files(ctx.root) == before
    end

    for states <- [["open"], [" OPEN "], ["Open", "open"]] do
      write_workflow(ctx, %{"tracker" => %{"active_states" => states}})

      assert {:ok, %{status: "passed", issue_count: 0}} =
               probe(ctx.path, fn "GET", "/repos/owner/repo/issues", params, nil, _ ->
                 assert params["state"] == "open"
                 send(self(), :github_polled)
                 {:ok, %{status: 200, body: []}}
               end)

      assert_received :github_polled
    end
  end

  test "CLI main exits nonzero and reports a preflight configuration failure in a fresh VM", ctx do
    write_workflow(ctx, %{"mvp" => %{"enabled" => false}})
    before = files(ctx.root)
    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)

    {output, status} =
      System.cmd(
        "timeout",
        ["--signal=KILL", "15s", "elixir"] ++
          code_paths ++
          [
            "-e",
            "SymphonyElixir.CLI.main(System.argv())",
            "--",
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
            "--preflight",
            ctx.path
          ],
        stderr_to_stdout: true
      )

    assert status == 1, output
    assert output =~ "Preflight failed: :mvp_preflight_requires_enabled_workflow"
    refute output =~ ~s("status":"passed")
    assert files(ctx.root) == before
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
        Client.fetch_issues_by_states_strict(states, tracker, fn "GET", _, _, nil, _ ->
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

  @tag timeout: 120_000
  test "the packaged escript separates JSON and diagnostics through retries and rejects malformed pages", ctx do
    # Build the actual configured entry point. Only the Req transport is replaced,
    # using an external fixture beam and VM config; the packaged code is untouched.
    {build_output, build_status} =
      System.cmd("timeout", ["--signal=KILL", "90s", "mix", "escript.build"], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert build_status == 0, build_output
    fixture_dir = Path.join(ctx.root, "fixture")
    File.mkdir_p!(fixture_dir)

    for {module, beam} <- Code.compile_file("test/fixtures/preflight_github_plug.ex") do
      File.write!(Path.join(fixture_dir, "#{module}.beam"), beam)
    end

    write_workflow(ctx)
    File.mkdir_p!(Path.join(ctx.root, "state/evidence"))
    File.write!(Path.join(ctx.root, "state/receipt.json"), ~s({"status":"awaiting_human"}))
    File.write!(Path.join(ctx.root, "state/evidence/keep"), "existing evidence")
    stderr_path = ctx.root <> ".stderr"
    on_exit(fn -> File.rm(stderr_path) end)
    full_page = Enum.map(1..100, &issue/1)
    unknown_state = Map.put(issue(101), "state", "bogus")

    for {responses, expected} <- [
          {[{1, {200, full_page}}, {2, {200, [issue(101)]}}], {:ok, 101}},
          {[{1, {200, []}}], {:ok, 0}},
          {[{1, {200, [%{}]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, [issue(1), %{}]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, full_page}}, {2, {200, [%{}]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, [unknown_state]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, [issue(1), unknown_state]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, full_page}}, {2, {200, [unknown_state]}}], {:error, ":github_unknown_payload"}},
          {[{1, {200, [Map.put(issue(1), "assignee", "alice")]}}], {:error, ":github_unknown_payload"}},
          {[{1, {403, %{}}}], {:error, "{:github_api_status, 403}"}},
          {[{1, {503, %{}}}, {1, {200, []}}], {:ok, 0}},
          {[{1, {503, %{}}}, {1, {200, full_page}}, {2, {503, %{}}}, {2, {200, [issue(101)]}}], {:ok, 101}},
          {List.duplicate({1, {503, %{}}}, 4), {:error, "{:github_api_status, 503}"}},
          {[{1, {200, full_page}} | List.duplicate({2, {503, %{}}}, 4)], {:error, "{:github_api_status, 503}"}},
          {List.duplicate({1, {:transport_error, :timeout}}, 4), {:error, ":github_api_request"}}
        ] do
      config_path = Path.join(fixture_dir, "preflight.config")
      # Keep the client's real retry policy and default attempt limit; skip only
      # the backoff wait in this transport fixture.
      config = [req: [default_options: [plug: {SymphonyElixir.PreflightGitHubPlug, responses}, retry_delay: 0]]]
      File.write!(config_path, :io_lib.format(~c"~tp.~n", [config]))
      before = files(ctx.root)

      {output, status} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(exec "$@" 2>"$PREFLIGHT_STDERR"),
            "preflight-test",
            "timeout",
            "--signal=KILL",
            "15s",
            "escript",
            "bin/symphony",
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
            "--preflight",
            ctx.path
          ],
          env: [
            {"ERL_FLAGS", "#{System.get_env("ERL_FLAGS")} -pa #{inspect(fixture_dir)} -config #{inspect(config_path)}"},
            {"PREFLIGHT_STDERR", stderr_path}
          ]
        )

      stderr = File.read!(stderr_path)
      requests = Regex.scan(~r/^preflight-request page=(\d+)$/m, stderr, capture: :all_but_first)
      assert requests == Enum.map(responses, fn {page, _} -> [to_string(page)] end), stderr

      page_count = responses |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
      assert length(Regex.scan(~r/retry: /, stderr)) == length(responses) - page_count, stderr

      if expected in [{:error, "{:github_api_status, 403}"}, {:error, "{:github_api_status, 503}"}] do
        assert stderr =~ "GitHub API request failed", stderr
      end

      case expected do
        {:ok, count} ->
          assert status == 0, output <> stderr
          assert Jason.decode!(output) == %{"mode" => "preflight", "status" => "passed", "issue_count" => count}
          refute stderr =~ "Preflight failed:"

        {:error, reason} ->
          assert status == 1, output <> stderr
          assert output == ""
          assert stderr =~ "Preflight failed:"
          assert stderr =~ reason
          refute stderr =~ ~s("status":"passed")
      end

      assert files(ctx.root) == before
    end
  end

  defp probe(path, request) do
    Preflight.run(path, fetch_issues: fn states, tracker -> Client.fetch_issues_by_states_strict(states, tracker, request) end)
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
