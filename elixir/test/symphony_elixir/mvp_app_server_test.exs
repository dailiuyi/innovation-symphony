defmodule SymphonyElixir.MVPAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.ModelServices

  test "MVP session freezes model and enforces read-only tool and output schema options" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-mvp-app-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MVP-1")
    trace_file = Path.join(test_root, "app-server.jsonl")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace)
    write_fake_app_server!(codex_binary)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "env SYMP_TEST_APP_SERVER_TRACE=#{shell_quote(trace_file)} SYMP_TEST_APP_SERVER_MODE=success #{shell_quote(codex_binary)} app-server",
      codex_turn_timeout_ms: 5_000
    )

    issue = %Issue{
      id: "mvp-1",
      identifier: "MVP-1",
      title: "Exercise the MVP app-server contract",
      description: "",
      state: "In Progress",
      url: "https://example.org/issues/MVP-1",
      labels: []
    }

    assert {:ok, session} =
             AppServer.start_session(workspace,
               model: "review-model",
               read_only: true,
               tools: false
             )

    try do
      schema = %{"type" => "object", "properties" => %{"approved" => %{"type" => "boolean"}}}

      assert {:ok, result} =
               AppServer.run_turn(session, "Review this workspace", issue,
                 model: "must-not-replace-the-session-model",
                 output_schema: schema,
                 tool_executor: fn _tool, _arguments -> flunk("disabled tools must not execute") end
               )

      assert result.result == :turn_completed
      assert result.output_text == "review approved"
    after
      AppServer.stop_session(session)
    end

    requests = read_trace!(trace_file)
    thread_start = Enum.find(requests, &(&1["method"] == "thread/start"))
    turn_start = Enum.find(requests, &(&1["method"] == "turn/start"))
    tool_response = Enum.find(requests, &(&1["id"] == "tool-call-1"))

    assert thread_start["params"]["model"] == "review-model"
    assert thread_start["params"]["sandbox"] == "read-only"
    refute Map.has_key?(thread_start["params"], "dynamicTools")

    assert turn_start["params"]["model"] == "review-model"
    assert turn_start["params"]["sandboxPolicy"] == %{"type" => "readOnly"}

    assert turn_start["params"]["outputSchema"] == %{
             "type" => "object",
             "properties" => %{"approved" => %{"type" => "boolean"}}
           }

    assert tool_response["result"]["success"] == false
    assert tool_response["result"]["output"] =~ "disabled"
  end

  test "MVP session propagates an unknown model error from app-server" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-mvp-app-server-unknown-model-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MVP-2")
    trace_file = Path.join(test_root, "app-server.jsonl")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace)
    write_fake_app_server!(codex_binary)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "env SYMP_TEST_APP_SERVER_TRACE=#{shell_quote(trace_file)} SYMP_TEST_APP_SERVER_MODE=unknown-model #{shell_quote(codex_binary)} app-server",
      codex_read_timeout_ms: 5_000
    )

    assert {:error, {:response_error, %{"code" => -32_602, "message" => "Unknown model"}}} =
             AppServer.start_session(workspace, model: "not-in-the-app-server-catalog")

    thread_start =
      trace_file
      |> read_trace!()
      |> Enum.find(&(&1["method"] == "thread/start"))

    assert thread_start["params"]["model"] == "not-in-the-app-server-catalog"
  end

  for mode <- ["startup-busy", "startup-noeol", "turn-busy", "turn-noeol"] do
    test "wall deadline bounds #{mode} and closes the port", %{test: test} do
      {workspace, issue, trace} = wall_test_context!(test, unquote(mode))
      ports_before = owned_ports()
      started = System.monotonic_time(:millisecond)

      assert {:error, :wall_timeout} =
               AppServer.run(workspace, "bounded turn", issue,
                 wall_timeout_ms: 250,
                 tools: false,
                 on_message: fn _ -> :ok end
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 200
      assert elapsed < 1_500
      assert owned_ports() == ports_before
      assert Process.get({AppServer, :wall_deadline}) == nil
      assert_fake_app_server_stopped!(trace)
    end
  end

  test "wall option validates early and its scope restores after a normal session", %{test: test} do
    for invalid <- [0, -1, "250", true] do
      assert {:error, :invalid_wall_timeout} = AppServer.run("unused", "unused", %{}, wall_timeout_ms: invalid)
    end

    {workspace, issue, _trace} = wall_test_context!(test, "success")
    key = {AppServer, :wall_deadline}
    Process.put(key, :outer_scope)

    try do
      assert {:ok, %{output_text: "review approved"}} =
               AppServer.run(workspace, "review", issue, wall_timeout_ms: 5_000, tools: false)

      assert Process.get(key) == :outer_scope
      assert {:ok, _} = AppServer.run(workspace, "legacy review", issue, tools: false)
      assert Process.get(key) == :outer_scope
    after
      Process.delete(key)
    end
  end

  defp wall_test_context!(test, mode) do
    root = Path.join(System.tmp_dir!(), "mvp-wall-#{test}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workspace = Path.join(root, "workspace")
    trace = Path.join(root, "trace.jsonl")
    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)
    write_fake_app_server!(binary)

    environment =
      "env SYMP_TEST_APP_SERVER_TRACE=#{shell_quote(trace)} SYMP_TEST_APP_SERVER_MODE=#{mode} " <>
        "SYMP_TEST_APP_SERVER_PID_FILE=#{shell_quote(trace <> ".pid")}"

    command = environment <> " " <> shell_quote(binary)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      codex_command: command,
      codex_read_timeout_ms: 5_000,
      codex_turn_timeout_ms: 5_000
    )

    issue = %Issue{id: "wall", identifier: "WALL-1", title: "Bounded session", state: "In Progress"}
    {workspace, issue, trace}
  end

  defp owned_ports do
    Port.list()
    |> Enum.filter(&(Port.info(&1, :connected) == {:connected, self()}))
    |> MapSet.new()
  end

  defp write_fake_app_server!(codex_binary) do
    File.write!(
      codex_binary,
      """
      #!/bin/sh
      count=0
      trace_file="$SYMP_TEST_APP_SERVER_TRACE"
      if [ -n "$SYMP_TEST_APP_SERVER_PID_FILE" ]; then
        printf '%s\\n' "$$" > "$SYMP_TEST_APP_SERVER_PID_FILE"
      fi

      busy_stream() {
        while :; do
          case "$SYMP_TEST_APP_SERVER_MODE" in
            *noeol) printf '%10000s' 'x' || exit 0 ;;
            *) printf '%s\\n' '{"id":999,"method":"test/progress","result":{}}' || exit 0 ;;
          esac
          sleep 0.002
        done
      }

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            case "$SYMP_TEST_APP_SERVER_MODE" in startup-*) busy_stream ;; esac
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            if [ "$SYMP_TEST_APP_SERVER_MODE" = "unknown-model" ]; then
              printf '%s\\n' '{"id":2,"error":{"code":-32602,"message":"Unknown model"}}'
              exit 0
            fi
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"mvp-thread"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"mvp-turn"}}}'
            case "$SYMP_TEST_APP_SERVER_MODE" in turn-*) busy_stream ;; esac
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"commentary","text":"checking the review requirements"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"review approved"}}}'
            printf '%s\\n' '{"method":"item/tool/call","id":"tool-call-1","params":{"tool":"unexposed_tool","arguments":{}}}'
            IFS= read -r tool_response
            printf '%s\\n' "$tool_response" >> "$trace_file"
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """
    )

    File.chmod!(codex_binary, 0o755)
    :ok
  end

  defp read_trace!(trace_file) do
    trace_file
    |> File.stream!()
    |> Enum.map(&Jason.decode!(String.trim(&1)))
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp assert_fake_app_server_stopped!(trace) do
    if :os.type() == {:unix, :linux} do
      pid = (trace <> ".pid") |> File.read!() |> String.trim()
      assert Regex.match?(~r/^[1-9][0-9]*$/, pid)

      assert Enum.any?(1..30, fn _ ->
               Process.sleep(50)
               not File.exists?("/proc/#{pid}")
             end),
             "fake app-server process #{pid} survived a closed port"
    end
  end

  test "persistent codex_home option is preserved and not cleaned up on stop_session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-persistent-home-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workspace = Path.join(test_root, "workspaces/MVP-1")
    custom_home = Path.join(test_root, "sandboxes/run-1/codex-home")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace)
    File.mkdir_p!(custom_home)
    write_fake_app_server!(codex_binary)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      codex_command: "#{shell_quote(codex_binary)} app-server",
      codex_turn_timeout_ms: 5_000
    )

    System.put_env("GH12_CODER_KEY", "test-key-coder")
    System.put_env("GH12_REVIEWER_KEY", "test-key-reviewer")

    on_exit(fn ->
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    settings = SymphonyElixir.ModelServicesFixture.settings(test_root)
    {:ok, service} = ModelServices.snapshot(settings, "coding", :coder, "fixture")
    service = Map.put(service, "command", "#{codex_binary} app-server")

    assert {:ok, session} =
             AppServer.start_session(workspace,
               model: "gpt-test",
               model_service: service,
               codex_home: custom_home,
               read_only: false,
               tools: false
             )

    assert File.exists?(Path.join(custom_home, "config.toml"))

    AppServer.stop_session(session)

    # Must NOT be deleted after session stop
    assert File.dir?(custom_home)
    assert File.exists?(Path.join(custom_home, "config.toml"))
  end

  test "ModelServices.standalone_run_home generates runtime sandboxes codex-home when sandbox disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-root-#{System.unique_integer([:positive])}"
      )

    state_dir = Path.join(test_root, "state")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, home} = ModelServices.standalone_run_home(%{state_dir: state_dir})
    assert is_binary(home)
    assert String.starts_with?(home, Path.join(test_root, "sandboxes"))
    assert String.ends_with?(home, "codex-home")
    assert File.dir?(home)

    # When sandbox is enabled, must return {:ok, nil} and not allocate a home
    assert {:ok, nil} =
             ModelServices.standalone_run_home(%{
               state_dir: state_dir,
               sandbox: %{enabled: true}
             })

    assert {:ok, nil} = ModelServices.standalone_run_home(%{state_dir: "/nonexistent/state/dir"})
    assert {:ok, nil} = ModelServices.standalone_run_home(%{})
  end

  test "ModelServices.prune_runs retains standalone run directory with open session file descriptor despite 50 newer runs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-prune-test-#{System.unique_integer([:positive])}")
    sandboxes = Path.join(test_root, "sandboxes")
    File.mkdir_p!(sandboxes)
    on_exit(fn -> File.rm_rf(test_root) end)

    # Create run-0 as standalone run (codex-home only)
    active_run = Path.join(sandboxes, "run-0")
    sessions_dir = Path.join([active_run, "codex-home", "sessions"])
    File.mkdir_p!(sessions_dir)
    transcript = Path.join(sessions_dir, "rollout-active.jsonl")
    file = File.open!(transcript, [:write])
    IO.binwrite(file, "initial session content\n")

    # Create 55 newer runs
    for i <- 1..55 do
      dir = Path.join(sandboxes, "run-#{i}")
      File.mkdir_p!(dir)
      File.touch!(dir, System.os_time(:second) + i)
    end

    ModelServices.prune_runs(sandboxes, 50)

    # active_run has an open file descriptor, must NOT be pruned
    assert File.dir?(active_run)
    assert File.regular?(transcript)

    # Writing to open file still works and path exists
    IO.binwrite(file, "subsequent session content\n")
    File.close(file)
  end

  test "ModelServices.prune_runs retains sandbox directory when export failed despite 50 newer runs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-prune-export-#{System.unique_integer([:positive])}")
    sandboxes = Path.join(test_root, "sandboxes")
    File.mkdir_p!(sandboxes)
    on_exit(fn -> File.rm_rf(test_root) end)

    # Create run-0 with failed export
    failed_run = Path.join(sandboxes, "run-0")
    scratch = Path.join(failed_run, "sandbox")
    File.mkdir_p!(scratch)
    export_dir = Path.join(scratch, "export")
    File.mkdir_p!(export_dir)
    File.write!(Path.join(export_dir, "candidate.txt"), "failed export code")
    result_path = Path.join(scratch, "result.json")
    File.write!(result_path, Jason.encode!(%{"cleanup_complete" => true, "export_complete" => false, "scratch_root" => scratch, "exit_status" => 1}))

    # Create 55 newer runs
    for i <- 1..55 do
      dir = Path.join(sandboxes, "run-#{i}")
      File.mkdir_p!(dir)
      File.touch!(dir, System.os_time(:second) + i)
    end

    ModelServices.prune_runs(sandboxes, 50)

    # failed_run must be preserved for operator inspection
    assert File.dir?(failed_run)
    assert File.read!(Path.join(export_dir, "candidate.txt")) == "failed export code"
  end

  test "ModelServices.prune_runs retains sandbox directory referenced by recovery journal despite 50 newer runs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-prune-recovery-#{System.unique_integer([:positive])}")
    sandboxes = Path.join(test_root, "sandboxes")
    workspace = Path.join(test_root, "workspace")
    import_dir = Path.join(workspace, ".symphony-import")
    File.mkdir_p!(sandboxes)
    File.mkdir_p!(import_dir)
    on_exit(fn -> File.rm_rf(test_root) end)

    # Create run-0 with completed export
    recovered_run = Path.join(sandboxes, "run-0")
    scratch = Path.join(recovered_run, "sandbox")
    export_dir = Path.join(scratch, "export")
    File.mkdir_p!(export_dir)
    File.write!(Path.join(scratch, "result.json"), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true, "scratch_root" => scratch, "exit_status" => 0}))

    # Journal in workspace references run-0
    journal = %{"schema" => 2, "export" => export_dir}
    File.write!(Path.join(import_dir, "journal.json"), Jason.encode!(journal))

    # Create 55 newer runs
    for i <- 1..55 do
      dir = Path.join(sandboxes, "run-#{i}")
      File.mkdir_p!(dir)
      File.touch!(dir, System.os_time(:second) + i)
    end

    ModelServices.prune_runs(sandboxes, 50)

    # recovered_run must be preserved because recovery journal references it
    assert File.dir?(recovered_run)
  end

  test "ModelServices.prune_runs retains sandbox directory referenced by recovery journal in disjoint workspace from receipt" do
    test_root = Path.join(System.tmp_dir!(), "symphony-prune-disjoint-#{System.unique_integer([:positive])}")
    sandboxes = Path.join(test_root, "sandboxes")
    state_dir = Path.join(test_root, "state")
    disjoint_workspace = Path.join(System.tmp_dir!(), "symphony-disjoint-ws-#{System.unique_integer([:positive])}")
    import_dir = Path.join(disjoint_workspace, ".symphony-import")

    File.mkdir_p!(sandboxes)
    File.mkdir_p!(state_dir)
    File.mkdir_p!(import_dir)

    on_exit(fn ->
      File.rm_rf(test_root)
      File.rm_rf(disjoint_workspace)
    end)

    # Create run-0 with completed export in sandboxes
    recovered_run = Path.join(sandboxes, "run-0")
    scratch = Path.join(recovered_run, "sandbox")
    export_dir = Path.join(scratch, "export")
    File.mkdir_p!(export_dir)
    File.write!(Path.join(scratch, "result.json"), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true, "scratch_root" => scratch, "exit_status" => 0}))

    # Journal in disjoint workspace references run-0
    journal = %{"schema" => 2, "export" => export_dir}
    File.write!(Path.join(import_dir, "journal.json"), Jason.encode!(journal))

    # Receipt in state dir points to disjoint workspace
    receipt = %{"issue_id" => "mvp-disjoint", "workspace" => disjoint_workspace}
    File.write!(Path.join(state_dir, "receipt-mvp-disjoint.json"), Jason.encode!(receipt))

    # Create 55 newer runs
    for i <- 1..55 do
      dir = Path.join(sandboxes, "run-#{i}")
      File.mkdir_p!(dir)
      File.touch!(dir, System.os_time(:second) + i)
    end

    ModelServices.prune_runs(sandboxes, 50)

    # recovered_run must be preserved because recovery journal in receipt workspace references it
    assert File.dir?(recovered_run)
  end

  test "ModelServices.prune_runs does not prune runs when peer process file descriptors cannot be confirmed" do
    test_root = Path.join(System.tmp_dir!(), "symphony-prune-unconfirmed-#{System.unique_integer([:positive])}")
    sandboxes = Path.join(test_root, "sandboxes")
    File.mkdir_p!(sandboxes)
    on_exit(fn -> File.rm_rf(test_root) end)

    # Create run-0
    target_run = Path.join(sandboxes, "run-0")
    File.mkdir_p!(target_run)

    # Create 55 newer runs
    for i <- 1..55 do
      dir = Path.join(sandboxes, "run-#{i}")
      File.mkdir_p!(dir)
      File.touch!(dir, System.os_time(:second) + i)
    end

    python = System.find_executable("python3")

    if python != nil and File.exists?("/proc") do
      script = """
      import ctypes, sys
      libc = ctypes.CDLL(None)
      libc.prctl(4, 0, 0, 0, 0)
      sys.stdout.write("READY\\n")
      sys.stdout.flush()
      sys.stdin.read()
      """

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          args: ["-c", script]
        ])

      receive do
        {^port, {:data, "READY\n"}} -> :ok
      after
        1000 -> :ok
      end

      try do
        ModelServices.prune_runs(sandboxes, 50)

        # Under unconfirmed usage state, deletion must not be authorized when /proc/<pid>/fd is eacces
        case File.stat("/proc/self") do
          {:ok, %{uid: 0}} ->
            :ok

          _ ->
            assert File.dir?(target_run)
        end
      after
        Port.close(port)
      end
    else
      :ok
    end
  end
end
