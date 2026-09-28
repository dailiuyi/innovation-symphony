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

  defp write_fake_app_server!(codex_binary) do
    File.write!(
      codex_binary,
      """
      #!/bin/sh
      count=0
      trace_file="$SYMP_TEST_APP_SERVER_TRACE"

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
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
end
