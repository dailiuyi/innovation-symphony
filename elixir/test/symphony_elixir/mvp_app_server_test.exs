defmodule SymphonyElixir.MVPAppServerTest do
  use SymphonyElixir.TestSupport

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
end
