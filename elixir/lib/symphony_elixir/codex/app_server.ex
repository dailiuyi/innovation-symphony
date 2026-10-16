defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}
  alias SymphonyElixir.Mvp.{ModelCatalog, ModelServices}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @environment_status_id 4
  @environment_info_id 5
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @wall_deadline_key {__MODULE__, :wall_deadline}
  @turn_protocol_key {__MODULE__, :turn_protocol}
  @turn_identity_key {__MODULE__, :turn_identity}
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          execution_environment: map() | nil,
          dynamic_tool_binding: map(),
          model: String.t() | nil,
          service_runtime: map() | nil,
          tools_enabled: boolean()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with_wall_timeout(Keyword.get(opts, :wall_timeout_ms), fn -> run_session(workspace, prompt, issue, opts) end)
  end

  defp run_session(workspace, prompt, issue, opts) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  # This process-local scope covers initialization and all turn reads without changing
  # the separately exposed start_session/run_turn API or its legacy idle timeouts.
  defp with_wall_timeout(timeout, fun) when is_nil(timeout) or (is_integer(timeout) and timeout > 0) do
    previous = Process.get(@wall_deadline_key)
    deadline = if timeout, do: System.monotonic_time(:millisecond) + timeout
    Process.put(@wall_deadline_key, deadline)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@wall_deadline_key), else: Process.put(@wall_deadline_key, previous)
    end
  end

  defp with_wall_timeout(_, _), do: {:error, :invalid_wall_timeout}

  defp read_budget(idle_timeout) do
    case Process.get(@wall_deadline_key) do
      nil ->
        {:ok, idle_timeout}

      deadline ->
        remaining = deadline - System.monotonic_time(:millisecond)
        if remaining > 0, do: {:ok, min(idle_timeout, remaining)}, else: {:error, :wall_timeout}
    end
  end

  defp read_timeout_error(idle_error) do
    case read_budget(0) do
      {:error, :wall_timeout} -> {:error, :wall_timeout}
      {:ok, _} -> {:error, idle_error}
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    model = Keyword.get(opts, :model)
    read_only = Keyword.get(opts, :read_only, false) == true
    tools_enabled = Keyword.get(opts, :tools, true) != false
    execution_environment = Keyword.get(opts, :execution_environment)
    binding = DynamicTool.bind()

    with :ok <- validate_model_option(model),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         :ok <- validate_execution_environment(execution_environment, worker_host, expanded_workspace),
         service = Keyword.get(opts, :model_service),
         :ok <- ModelServices.credential_boundary(service, [expanded_workspace]),
         {:ok, service_runtime} <- prepare_service(service, execution_environment, worker_host, model, Keyword.get(opts, :codex_home)),
         {:ok, port} <- start_port(expanded_workspace, worker_host, binding, execution_environment, service_runtime) do
      metadata = port_metadata(port, worker_host)
      session_workspace = if execution_environment, do: execution_environment.cwd, else: expanded_workspace

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           session_policies <- apply_execution_environment(session_policies, execution_environment),
           session_policies <- apply_read_only_policy(session_policies, read_only),
           {:ok, thread_id} <-
             do_start_session(
               port,
               session_workspace,
               session_policies,
               binding,
               model,
               tools_enabled
             ) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: session_workspace,
           execution_environment: execution_environment,
           worker_host: worker_host,
           dynamic_tool_binding: binding,
           model: model,
           service_runtime: service_runtime,
           tools_enabled: tools_enabled
         }}
      else
        {:error, reason} ->
          stop_port(port)
          cleanup_service(service_runtime)
          protected_result({:error, reason}, service_runtime)
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding,
          model: model,
          tools_enabled: tools_enabled
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    output_schema = Keyword.get(opts, :output_schema)

    turn_state = %{
      port: port,
      metadata: metadata,
      approval_policy: approval_policy,
      auto_approve_requests: auto_approve_requests,
      turn_sandbox_policy: turn_sandbox_policy,
      thread_id: thread_id,
      workspace: workspace,
      model: model,
      execution_environment: Map.get(session, :execution_environment),
      service_runtime: Map.get(session, :service_runtime)
    }

    callbacks = %{
      on_message: on_message,
      tool_executor: turn_tool_executor(tools_enabled, dynamic_tool_binding, issue, opts),
      auto_approve_requests: auto_approve_requests
    }

    if is_nil(output_schema) or is_map(output_schema) do
      service_runtime = Map.get(session, :service_runtime)
      guarded_handler = fn message -> callbacks.on_message.(redact_service_error(message, service_runtime)) end
      guarded = %{callbacks | on_message: guarded_handler}
      result = with_turn_protocol(Keyword.get(opts, :turn_protocol, "legacy-fixture-v0"), fn -> start_and_complete_turn(turn_state, guarded, prompt, issue, output_schema) end)
      protected_result(result, service_runtime)
    else
      {:error, :invalid_output_schema}
    end
  end

  defp with_turn_protocol(protocol, fun) when protocol in ["legacy-fixture-v0", "codex-0.160.0-turn-v1"] do
    previous = Process.get(@turn_protocol_key)
    identity = Process.get(@turn_identity_key)
    Process.put(@turn_protocol_key, protocol)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@turn_protocol_key), else: Process.put(@turn_protocol_key, previous)
      if is_nil(identity), do: Process.delete(@turn_identity_key), else: Process.put(@turn_identity_key, identity)
    end
  end

  defp with_turn_protocol(_, _), do: {:error, :unsupported_turn_protocol}

  defp turn_tool_executor(true, dynamic_tool_binding, issue, opts) do
    Keyword.get(opts, :tool_executor, fn tool, arguments ->
      DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
    end)
  end

  defp turn_tool_executor(false, _dynamic_tool_binding, _issue, _opts) do
    fn _tool, _arguments ->
      %{"success" => false, "output" => "Dynamic tools are disabled for this session"}
    end
  end

  defp start_and_complete_turn(turn_state, callbacks, prompt, issue, output_schema) do
    turn_options = %{
      prompt: prompt,
      issue: issue,
      workspace: turn_state.workspace,
      approval_policy: turn_state.approval_policy,
      turn_sandbox_policy: turn_state.turn_sandbox_policy,
      model: turn_state.model,
      output_schema: output_schema,
      execution_environment: turn_state.execution_environment,
      service_runtime: turn_state.service_runtime
    }

    case start_turn(turn_state.port, turn_state.thread_id, turn_options) do
      {:ok, turn_id} -> complete_started_turn(turn_state, callbacks, issue, turn_id)
      {:error, reason} -> startup_failed(turn_state, callbacks.on_message, issue, reason)
    end
  end

  defp complete_started_turn(turn_state, callbacks, issue, turn_id) do
    Process.put(@turn_identity_key, {turn_state.thread_id, turn_id})
    session_id = "#{turn_state.thread_id}-#{turn_id}"
    Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(
      callbacks.on_message,
      :session_started,
      %{session_id: session_id, thread_id: turn_state.thread_id, turn_id: turn_id},
      turn_state.metadata
    )

    case await_turn_completion(
           turn_state.port,
           callbacks.on_message,
           callbacks.tool_executor,
           callbacks.auto_approve_requests
         ) do
      {:ok, output_text} ->
        Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           # Supported Codex Turn messages expose no actual-model telemetry.
           # Thread.model is configured state, not confirmation of inference.
           actual_model: nil,
           result: :turn_completed,
           output_text: output_text,
           session_id: session_id,
           thread_id: turn_state.thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        turn_failed(turn_state, callbacks.on_message, issue, session_id, reason)
    end
  end

  defp startup_failed(turn_state, on_message, issue, reason) do
    reason = redact_service_error(reason, turn_state.service_runtime)
    Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
    emit_message(on_message, :startup_failed, %{reason: reason}, turn_state.metadata)
    {:error, reason}
  end

  defp turn_failed(turn_state, on_message, issue, session_id, reason) do
    reason = redact_service_error(reason, turn_state.service_runtime)
    Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, reason: reason},
      turn_state.metadata
    )

    {:error, reason}
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port} = session) when is_port(port) do
    stop_port(port)
    cleanup_service(Map.get(session, :service_runtime))
    :ok
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  @doc "Discover every page exposed by this account's AppServer, without starting an inference thread."
  @spec list_models(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_models(service, opts \\ []) do
    with_wall_timeout(Keyword.get(opts, :wall_timeout_ms, 60_000), fn ->
      with {:ok, runtime} <- prepare_service(service, nil, nil, service["model"]) do
        try do
          protected_result(discover_models(runtime), runtime)
        after
          cleanup_service(runtime)
        end
      end
    end)
  end

  defp discover_models(runtime) do
    binding = DynamicTool.bind()

    with {:ok, port} <- start_port(runtime.home, nil, binding, nil, runtime) do
      try do
        with :ok <- send_initialize(port), do: model_pages(port, nil, [], %{})
      after
        stop_port(port)
      end
    end
  end

  @spec model_pages(port(), String.t() | nil, [map()], map()) :: {:ok, [map()]} | {:error, term()}
  defp model_pages(port, cursor, models, seen) do
    send_message(port, %{"id" => 6, "method" => "model/list", "params" => %{"cursor" => cursor, "limit" => 100, "includeHidden" => true}})

    case await_response(port, 6) do
      {:ok, %{"data" => data} = page} when is_list(data) ->
        next = page["nextCursor"]

        cond do
          is_nil(next) -> {:ok, models ++ data}
          not is_binary(next) -> {:error, :model_catalog_pagination_invalid}
          Map.has_key?(seen, next) -> {:error, :model_catalog_pagination_invalid}
          true -> model_pages(port, next, models ++ data, Map.put(seen, next, true))
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :model_discovery_failed}
    end
  end

  defp prepare_service(service, environment, host, model, codex_home \\ nil)
  defp prepare_service(nil, _, _, _, _), do: {:ok, nil}

  defp prepare_service(service, environment, host, model, codex_home) do
    with :ok <- ModelServices.validate_snapshot(service),
         true <- (is_nil(host) and ModelCatalog.supported_adapter?(service)) or {:error, :model_provider_not_supported},
         true <- model == service["model"] or {:error, :model_service_model_mismatch},
         :ok <- ModelServices.identity_matches(service),
         {:ok, credential} <- ModelServices.credential(service["credential_ref"]) do
      service_home(service, environment, credential, codex_home)
    end
  end

  defp service_home(service, environment, credential, _codex_home) when is_map(environment),
    do: {:ok, service_runtime(service, environment.codex_home, false, credential)}

  defp service_home(service, nil, credential, codex_home) when is_binary(codex_home) do
    with :ok <- File.mkdir_p(codex_home),
         :ok <- File.chmod(codex_home, 0o700),
         :ok <- ModelServices.write_home(codex_home, service, credential) do
      {:ok, service_runtime(service, codex_home, false, credential)}
    else
      _ ->
        {:error, :model_service_home_failed}
    end
  end

  defp service_home(service, nil, credential, nil) do
    home = Path.join(System.tmp_dir!(), "symphony-model-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

    with :ok <- File.mkdir(home), :ok <- File.chmod(home, 0o700), :ok <- ModelServices.write_home(home, service, credential) do
      {:ok, service_runtime(service, home, true, credential)}
    else
      _ ->
        File.rm_rf(home)
        {:error, :model_service_home_failed}
    end
  end

  defp service_runtime(service, home, temporary, credential) do
    secrets = credential_secrets(credential)
    %{service: service, home: home, temporary: temporary, credential: credential, secrets: secrets}
  end

  defp credential_secrets({:env, _, secret}), do: [secret]

  defp credential_secrets({:home, home}) do
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")), {:ok, auth} <- Jason.decode(raw) do
      secret_values(auth)
    else
      _ -> []
    end
  end

  defp secret_values(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&secret_values/1)
  defp secret_values(value) when is_binary(value) and byte_size(value) >= 8, do: [value]
  defp secret_values(_), do: []

  defp protected_result(result, nil), do: result

  defp protected_result(result, runtime) do
    case redact_service_error(result, runtime) do
      {:error, reason} -> {:error, ModelServices.failure_reason(reason)}
      value -> value
    end
  end

  defp cleanup_service(%{temporary: true, home: home}), do: File.rm_rf(home)
  defp cleanup_service(_), do: :ok
  defp service_port_env(nil), do: []

  defp service_port_env(runtime) do
    common = [{~c"CODEX_HOME", String.to_charlist(runtime.home)}, {~c"OPENAI_API_KEY", false}, {~c"CODEX_API_KEY", false}, {~c"OPENAI_BASE_URL", false}]

    case runtime.credential do
      {:env, name, value} -> common ++ [{String.to_charlist(name), false}, {~c"SYMPHONY_MODEL_KEY", String.to_charlist(value)}]
      {:home, _} -> common ++ [{~c"SYMPHONY_MODEL_KEY", false}]
    end
  end

  defp redact_service_error(value, %{secrets: secrets}), do: Enum.reduce(secrets, value, &redact_value(&2, &1))
  defp redact_service_error(value, _), do: value
  defp redact_value(value, secret) when is_binary(value), do: String.replace(value, secret, "[redacted]")
  defp redact_value(%_{} = value, _secret), do: value
  defp redact_value(value, secret) when is_map(value), do: Map.new(value, fn {key, item} -> {key, redact_value(item, secret)} end)
  defp redact_value(value, secret) when is_list(value), do: Enum.map(value, &redact_value(&1, secret))
  defp redact_value(value, secret) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&redact_value(&1, secret)) |> List.to_tuple()
  defp redact_value(value, _), do: value

  defp port_env(binding, environment, runtime) do
    tracker_secret_port_env(binding) ++ execution_environment_port_env(environment) ++ service_port_env(runtime)
  end

  defp start_port(workspace, nil, dynamic_tool_binding, execution_environment, runtime) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding, runtime))],
            cd: String.to_charlist(if(runtime, do: runtime.home, else: host_config_cwd(workspace, execution_environment))),
            env: port_env(dynamic_tool_binding, execution_environment, runtime),
            line: @port_line_bytes
          ]
        )

      if runtime, do: Process.put({__MODULE__, port}, runtime)
      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, nil, nil) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding, runtime) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{if runtime, do: runtime.service["command"], else: Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp apply_read_only_policy(%{execution_environment: %{read_only: true}} = session_policies, true), do: session_policies

  defp apply_read_only_policy(session_policies, true) do
    %{
      session_policies
      | thread_sandbox: "read-only",
        turn_sandbox_policy: %{"type" => "readOnly"}
    }
  end

  defp apply_read_only_policy(session_policies, false), do: session_policies

  # This option is supplied only by the controller after preparing an external sandbox.
  # The host-only CODEX_HOME must contain its trusted environments.toml and credentials.
  defp validate_execution_environment(nil, _worker_host, _workspace), do: :ok

  defp validate_execution_environment(%{id: id, cwd: cwd, codex_home: home} = environment, nil, workspace)
       when is_binary(id) and is_binary(cwd) and is_binary(home) do
    with true <- Map.keys(environment) -- [:codex_home, :cwd, :id, :read_only] == [],
         true <- Map.get(environment, :read_only, false) in [true, false],
         true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, id) and id != "local",
         true <- String.starts_with?(cwd, "/") and cwd != "/" and not String.contains?(cwd, ["\n", "\r", <<0>>]),
         true <- Path.expand(cwd) == cwd,
         true <- Path.type(home) == :absolute and not String.contains?(home, ["\n", "\r", <<0>>]),
         {:ok, canonical_home} <- PathSafety.canonicalize(home),
         true <- canonical_home == home and File.dir?(home),
         false <- canonical_home == workspace or String.starts_with?(canonical_home, workspace <> "/"),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(home, "environments.toml")) do
      :ok
    else
      _ -> {:error, :invalid_execution_environment}
    end
  end

  defp validate_execution_environment(_, _, _), do: {:error, :invalid_execution_environment}

  defp execution_environment_port_env(nil), do: []

  defp execution_environment_port_env(%{codex_home: home}) do
    [{~c"CODEX_HOME", String.to_charlist(home)}] ++
      Enum.map(
        ~w(CODEX_EXEC_SERVER_URL CODEX_EXEC_SERVER_NOISE_REGISTRY_URL CODEX_EXEC_SERVER_NOISE_ENVIRONMENT_ID CODEX_EXEC_SERVER_NOISE_AUTH_TOKEN CODEX_EXEC_SERVER_NOISE_CHATGPT_ACCOUNT_ID),
        &{String.to_charlist(&1), false}
      )
  end

  defp apply_execution_environment(policies, nil), do: policies

  # Three-field bindings predate the kernel policy marker. Preserve their Codex
  # sandbox contract; the trusted Linux executor always supplies read_only.
  defp apply_execution_environment(policies, environment) when not is_map_key(environment, :read_only) do
    policies
    |> Map.put(:thread_sandbox, "workspace-write")
    |> Map.put(:turn_sandbox_policy, %{
      "type" => "workspaceWrite",
      "writableRoots" => [environment.cwd, "/tmp", "/home/coder"],
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    })
    |> Map.put(:execution_environment, environment)
  end

  defp apply_execution_environment(policies, environment) do
    policies
    |> Map.put(:thread_sandbox, "workspace-write")
    # The trusted executor already enforces namespaces, mounts and budgets.
    # Requesting another workspaceWrite sandbox inside it makes Codex create a
    # nested bubblewrap namespace, which the isolated Linux worker cannot create.
    # Local fallback is still rejected by verify_execution_environment/2.
    |> Map.put(:turn_sandbox_policy, %{
      "type" => "externalSandbox",
      "networkAccess" => "enabled"
    })
    |> Map.put(:execution_environment, environment)
  end

  defp environment_params(params, nil), do: params

  defp environment_params(params, %{id: id, cwd: cwd, codex_home: home}) do
    params
    |> Map.put("cwd", home)
    |> Map.put("environments", [%{"environmentId" => id, "cwd" => cwd}])
  end

  # Top-level cwd is also used for host configuration discovery. Keep it away
  # from candidate-controlled project files; only the selected executor uses cwd.
  defp host_config_cwd(workspace, nil), do: workspace
  defp host_config_cwd(_workspace, %{codex_home: home}), do: home

  defp validate_model_option(nil), do: :ok
  defp validate_model_option(model) when is_binary(model) and byte_size(model) > 0, do: :ok
  defp validate_model_option(_model), do: {:error, :invalid_model}

  defp maybe_put_model(params, nil), do: params
  defp maybe_put_model(params, model), do: Map.put(params, "model", model)

  defp completed_agent_message_text(%{
         "params" => %{
           "item" => %{
             "type" => "agentMessage",
             "text" => text
           }
         }
       })
       when is_binary(text),
       do: text

  defp completed_agent_message_text(_payload), do: nil

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, model, tools_enabled) do
    with :ok <- send_initialize(port),
         :ok <- verify_execution_environment(port, Map.get(session_policies, :execution_environment)) do
      start_thread(port, workspace, session_policies, dynamic_tool_binding, model, tools_enabled)
    end
  end

  defp verify_execution_environment(_port, nil), do: :ok

  defp verify_execution_environment(port, %{id: id, cwd: cwd}) do
    send_message(port, %{"method" => "environment/status", "id" => @environment_status_id, "params" => %{"environmentId" => "local"}})

    case await_response(port, @environment_status_id) do
      {:ok, %{"status" => "unknown"}} ->
        send_message(port, %{"method" => "environment/info", "id" => @environment_info_id, "params" => %{"environmentId" => id}})

        with {:ok, %{"cwd" => reported}} <- await_response(port, @environment_info_id),
             true <- reported == "file://" <> URI.encode(cwd) do
          :ok
        else
          _ -> {:error, :execution_environment_unavailable}
        end

      _ ->
        {:error, :execution_environment_local_fallback}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox} = policies,
         dynamic_tool_binding,
         model,
         tools_enabled
       ) do
    params = %{
      "approvalPolicy" => approval_policy,
      "sandbox" => thread_sandbox,
      "cwd" => workspace
    }

    params = if tools_enabled, do: Map.put(params, "dynamicTools", dynamic_tool_binding.tool_specs), else: params
    params = maybe_put_model(params, model)
    params = environment_params(params, Map.get(policies, :execution_environment))

    send_message(port, %{"method" => "thread/start", "id" => @thread_start_id, "params" => params})

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, options) do
    params = %{
      "threadId" => thread_id,
      "input" => [
        %{
          "type" => "text",
          "text" => options.prompt
        }
      ],
      "cwd" => options.workspace,
      "title" => "#{options.issue.identifier}: #{options.issue.title}",
      "approvalPolicy" => options.approval_policy,
      "sandboxPolicy" => options.turn_sandbox_policy
    }

    params = maybe_put_model(params, options.model)
    effort = get_in(options, [:service_runtime, :service, "parameters", "reasoning_effort"])
    params = if effort, do: Map.put(params, "effort", effort), else: params
    params = environment_params(params, options.execution_environment)
    params = if is_map(options.output_schema), do: Map.put(params, "outputSchema", options.output_schema), else: params

    send_message(port, %{"method" => "turn/start", "id" => @turn_start_id, "params" => params})

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      ""
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests, output_text) do
    # Check before receive as well as clamping after: a hot mailbox must not starve
    # an expired deadline by continually matching messages ahead of an after 0.
    with {:ok, wait_ms} <- read_budget(timeout_ms) do
      state = receive_state(timeout_ms, tool_executor, auto_approve_requests, output_text)
      receive_turn(port, on_message, pending_line, state, wait_ms)
    end
  end

  defp receive_turn(port, on_message, pending_line, state, wait_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          state
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          state.timeout_ms,
          pending_line <> to_string(chunk),
          state.tool_executor,
          state.auto_approve_requests,
          state.output_text
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      wait_ms ->
        read_timeout_error(:turn_timeout)
    end
  end

  defp receive_state(timeout_ms, tool_executor, auto_approve_requests, output_text) do
    %{
      timeout_ms: timeout_ms,
      tool_executor: tool_executor,
      auto_approve_requests: auto_approve_requests,
      output_text: output_text
    }
  end

  defp handle_incoming(port, on_message, data, state) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, payload} -> handle_decoded_incoming(port, on_message, payload, payload_string, state)
      {:error, _reason} -> handle_malformed_incoming(port, on_message, payload_string, state)
    end
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => "turn/completed"} = payload, raw, state) do
    case checked_completion_outcome(payload) do
      :ok ->
        emit_turn_event(on_message, :turn_completed, payload, raw, port, payload)
        {:ok, state.output_text}

      {:error, {:turn_failed, error}} ->
        failed_turn(port, on_message, payload, raw, error)

      {:error, {:turn_cancelled, turn}} = error ->
        emit_turn_event(on_message, :turn_cancelled, payload, raw, port, turn)
        error

      error ->
        error
    end
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => "configWarning"} = payload, raw, state) do
    with :ok <- configuration_warning(port, payload), do: handle_turn_method(port, on_message, payload, raw, state)
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => "item/completed"} = payload, raw, state) do
    emit_message(on_message, :notification, %{payload: payload, raw: raw}, metadata_from_message(port, payload))
    updated_state = %{state | output_text: completed_agent_message_text(payload) || state.output_text}
    continue_receive(port, on_message, updated_state)
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => "turn/failed", "params" => params} = payload, raw, _state) do
    emit_turn_event(on_message, :turn_failed, payload, raw, port, params)
    {:error, {:turn_failed, params}}
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => "turn/cancelled", "params" => params} = payload, raw, _state) do
    emit_turn_event(on_message, :turn_cancelled, payload, raw, port, params)
    {:error, {:turn_cancelled, params}}
  end

  defp handle_decoded_incoming(port, on_message, %{"method" => method} = payload, raw, state)
       when is_binary(method) do
    handle_turn_method(port, on_message, payload, raw, state)
  end

  defp handle_decoded_incoming(port, on_message, payload, raw, state) do
    emit_message(on_message, :other_message, %{payload: payload, raw: raw}, metadata_from_message(port, payload))
    continue_receive(port, on_message, state)
  end

  defp checked_completion_outcome(payload) do
    case Process.get(@turn_protocol_key, "legacy-fixture-v0") do
      "codex-0.160.0-turn-v1" ->
        expected = Process.get(@turn_identity_key)
        actual = {get_in(payload, ["params", "threadId"]), get_in(payload, ["params", "turn", "id"])}
        if actual == expected, do: completion_outcome(payload), else: {:error, :invalid_turn_completion}

      _ ->
        completion_outcome(payload)
    end
  rescue
    _ -> {:error, :invalid_turn_completion}
  end

  defp completion_outcome(payload) when not is_map_key(payload, "params"), do: missing_turn_outcome()
  defp completion_outcome(%{"params" => %{"turn" => turn}}), do: turn_outcome(turn)

  defp completion_outcome(%{"params" => %{"error" => error}}) when not is_nil(error),
    do: {:error, {:turn_failed, error}}

  # Older versions omit the entire Turn; explicit null/malformed Turns fail closed.
  defp completion_outcome(%{"params" => params}) when is_map(params), do: missing_turn_outcome()
  defp completion_outcome(_), do: {:error, :invalid_turn_completion}

  defp missing_turn_outcome do
    if Process.get(@turn_protocol_key, "legacy-fixture-v0") == "legacy-fixture-v0",
      do: :ok,
      else: {:error, :invalid_turn_completion}
  end

  defp turn_outcome(%{"status" => "completed", "error" => error}) when not is_nil(error),
    do: {:error, {:turn_failed, error}}

  defp turn_outcome(%{"status" => "completed"}), do: :ok
  defp turn_outcome(%{"status" => "failed"} = turn), do: {:error, {:turn_failed, turn["error"] || turn}}
  defp turn_outcome(%{"status" => "interrupted"} = turn), do: {:error, {:turn_cancelled, turn}}
  defp turn_outcome(_), do: {:error, :invalid_turn_completion}

  defp failed_turn(port, on_message, payload, raw, error) do
    emit_turn_event(on_message, :turn_failed, payload, raw, port, error)
    {:error, {:turn_failed, error}}
  end

  defp handle_malformed_incoming(port, on_message, raw, state) do
    log_non_json_stream_line(raw, "turn stream", port)

    if protocol_message_candidate?(raw) do
      emit_message(
        on_message,
        :malformed,
        %{payload: raw, raw: raw},
        metadata_from_message(port, %{raw: raw})
      )
    end

    continue_receive(port, on_message, state)
  end

  defp continue_receive(port, on_message, state) do
    receive_loop(
      port,
      on_message,
      state.timeout_ms,
      "",
      state.tool_executor,
      state.auto_approve_requests,
      state.output_text
    )
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(port, on_message, payload, payload_string, state) do
    method = payload["method"]
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           state.tool_executor,
           state.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        continue_receive(port, on_message, state)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          continue_receive(port, on_message, state)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    with {:ok, wait_ms} <- read_budget(timeout_ms) do
      receive_response(port, request_id, timeout_ms, pending_line, wait_ms)
    end
  end

  defp receive_response(port, request_id, timeout_ms, pending_line, wait_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      wait_ms ->
        read_timeout_error(:response_timeout)
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{"method" => "configWarning"} = warning} ->
        with :ok <- configuration_warning(port, warning), do: with_timeout_response(port, request_id, timeout_ms, "")

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(redact_service_error(other, Process.get({__MODULE__, port})))}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream", port)
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp configuration_warning(port, warning) do
    if Process.get({__MODULE__, port}) && invalid_configuration_warning?(warning),
      do: {:error, :model_service_configuration_invalid},
      else: :ok
  end

  defp invalid_configuration_warning?(%{"params" => %{"summary" => summary} = params}) when is_binary(summary) do
    details = params["details"]

    not (is_nil(details) or is_binary(details)) or
      Regex.match?(~r/invalid config(?:uration)?|(?:using|fall(?:ing)? back to) defaults/i, summary <> " " <> (details || ""))
  end

  defp invalid_configuration_warning?(_), do: true

  defp log_non_json_stream_line(data, stream_label, port) do
    data = redact_service_error(data, Process.get({__MODULE__, port}))

    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    Process.delete({__MODULE__, port})

    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
