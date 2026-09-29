defmodule SymphonyElixir.AppServerEnvironmentTest do
  use SymphonyElixir.TestSupport

  test "external executor is the only environment and credentials stay in host-only home" do
    context = context!()
    inherited = System.get_env("CODEX_EXEC_SERVER_URL")
    System.put_env("CODEX_EXEC_SERVER_URL", "ws://inherited-invalid")
    on_exit(fn -> restore_env("CODEX_EXEC_SERVER_URL", inherited) end)

    assert {:ok, session} = start_external(context)

    try do
      assert session.workspace == "/workspace"
      assert {:ok, _} = AppServer.run_turn(session, "test", context.issue)
    after
      AppServer.stop_session(session)
    end

    home = context.environment.codex_home
    assert File.read!(context.env_trace) == home <> "\nunset\n" <> home <> "\n"
    assert System.get_env("CODEX_EXEC_SERVER_URL") == "ws://inherited-invalid"
    requests = requests!(context)
    methods = ~w(initialize initialized environment/status environment/info thread/start turn/start)
    assert Enum.map(requests, & &1["method"]) == methods

    for method <- ["thread/start", "turn/start"] do
      params = Enum.find(requests, &(&1["method"] == method))["params"]
      assert params["cwd"] == context.environment.codex_home
      assert params["environments"] == [%{"environmentId" => "task", "cwd" => "/workspace"}]
    end

    thread = Enum.find(requests, &(&1["method"] == "thread/start"))["params"]
    turn = Enum.find(requests, &(&1["method"] == "turn/start"))["params"]
    assert thread["sandbox"] == "workspace-write"
    refute Map.has_key?(thread, "dynamicTools")

    assert turn["sandboxPolicy"] == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/workspace", "/tmp", "/home/coder"],
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "read-only review keeps the external environment binding" do
    context = context!()
    assert {:ok, session} = start_external(context, read_only: true)

    try do
      assert {:ok, _} = AppServer.run_turn(session, "review", context.issue)
    after
      AppServer.stop_session(session)
    end

    turn = Enum.find(requests!(context), &(&1["method"] == "turn/start"))["params"]
    assert turn["sandboxPolicy"] == %{"type" => "readOnly"}
    assert turn["environments"] == [%{"environmentId" => "task", "cwd" => "/workspace"}]
  end

  test "legacy session does not probe or add remote environments" do
    context = context!()
    assert {:ok, session} = AppServer.start_session(context.workspace, tools: false)

    try do
      assert {:ok, _} = AppServer.run_turn(session, "legacy", context.issue)
    after
      AppServer.stop_session(session)
    end

    requests = requests!(context)
    assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/start", "turn/start"]
    thread = Enum.find(requests, &(&1["method"] == "thread/start"))["params"]
    assert thread["sandbox"] == "workspace-write"
    assert thread["cwd"] == context.workspace
    refute Map.has_key?(thread, "environments")
  end

  test "invalid binding is rejected before starting the app server" do
    context = context!()

    for binding <- [
          %{},
          Map.put(context.environment, :id, "local"),
          Map.put(context.environment, :id, "bad/id"),
          Map.put(context.environment, :cwd, "/workspace/../outside"),
          Map.put(context.environment, :cwd, "/"),
          Map.put(context.environment, :codex_home, "relative"),
          Map.put(context.environment, :codex_home, context.workspace),
          Map.put(context.environment, :url, "ws://untrusted")
        ] do
      result = AppServer.start_session(context.workspace, execution_environment: binding)
      assert {:error, :invalid_execution_environment} = result
    end

    assert {:error, :invalid_execution_environment} = start_external(context, worker_host: "remote-host")

    File.rm!(Path.join(context.environment.codex_home, "environments.toml"))
    assert {:error, :invalid_execution_environment} = start_external(context)
    refute File.exists?(context.trace)
  end

  @unavailable :execution_environment_unavailable
  @local_fallback :execution_environment_local_fallback
  for {mode, reason} <- [{"local", @local_fallback}, {"disconnected", @unavailable}, {"wrong-cwd", @unavailable}] do
    test "rejects #{mode} without starting a model thread" do
      context = context!(unquote(mode))
      assert {:error, unquote(reason)} = start_external(context)
      refute Enum.any?(requests!(context), &(&1["method"] == "thread/start"))
    end
  end

  defp start_external(context, options \\ []) do
    options = Keyword.merge([execution_environment: context.environment, tools: false], options)
    AppServer.start_session(context.workspace, options)
  end

  defp requests!(context) do
    context.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp context!(mode \\ "ready") do
    root = Path.join(System.tmp_dir!(), "symphony-environment-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workspace = Path.join(root, "workspaces/task")
    home = Path.join(root, "host-home")
    binary = Path.join(root, "fake-codex")
    trace = Path.join(root, "trace.jsonl")
    env_trace = Path.join(root, "env.txt")
    File.mkdir_p!(workspace)
    File.mkdir_p!(home)
    File.write!(Path.join(home, "environments.toml"), "default = \"task\"\ninclude_local = false\n")

    File.write!(binary, """
    #!/bin/sh
    printf '%s\\n%s\\n%s\\n' "$CODEX_HOME" "${CODEX_EXEC_SERVER_URL-unset}" "$PWD" > '#{env_trace}'
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{trace}'
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"environment/status"'*)
          if [ '#{mode}' = local ]; then status=ready; else status=unknown; fi
          printf '{"id":4,"result":{"status":"%s"}}\\n' "$status" ;;
        *'"method":"environment/info"'*)
          case '#{mode}' in
            disconnected) printf '%s\\n' '{"id":5,"error":{"code":-32603,"message":"disconnected"}}' ;;
            wrong-cwd) printf '%s\\n' '{"id":5,"result":{"cwd":"file:///other"}}' ;;
            *) printf '%s\\n' '{"id":5,"result":{"cwd":"file:///workspace"}}' ;;
          esac ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn"}}}'
          printf '%s\\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: "'#{binary}'", codex_read_timeout_ms: 2_000)

    %{
      workspace: workspace,
      environment: %{id: "task", cwd: "/workspace", codex_home: home},
      trace: trace,
      env_trace: env_trace,
      issue: %Issue{id: "environment", identifier: "ENV-1", title: "Isolated tests", state: "In Progress"}
    }
  end
end
