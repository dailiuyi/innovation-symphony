defmodule SymphonyElixir.Mvp do
  @moduledoc "Opt-in finite delivery gate inside the upstream worker lifecycle."

  require Logger
  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Mvp.{ExecutionReadiness, Executor, Intake, Maintenance, ModelServices, Receipt, RestartRecovery}

  @preserved_failure_statuses ["publish_pending", "comment_pending", "awaiting_external"]

  @spec available?(map()) :: boolean()
  def available?(issue) do
    case Config.mvp_settings() do
      {:ok, %{enabled: false, configured: false}} ->
        true

      {:ok, %{enabled: false}} ->
        false

      {:ok, settings} ->
        Maintenance.open(settings) == :ok and ExecutionReadiness.backend_ready?(settings) and
          if Receipt.exists?(settings, issue) do
            RestartRecovery.eligible?(Receipt.path(settings, issue), settings)
          else
            ExecutionReadiness.intake_open(settings) == :ok and Intake.ready?(issue, settings.ready_label)
          end

      {:error, _} ->
        false
    end
  end

  @doc "Check admission before the scheduler creates an in-memory claim or starts a worker."
  @spec dispatch_readiness(map()) :: :ok | {:error, term()}
  def dispatch_readiness(issue) do
    case Config.mvp_settings() do
      {:ok, %{enabled: true} = settings} ->
        with :ok <- Maintenance.open(settings) do
          dispatch_enabled(issue, settings)
        end

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  defp dispatch_enabled(issue, settings) do
    if Receipt.exists?(settings, issue) do
      with {:ok, _} <- resume_models(issue, settings, []), do: :ok
    else
      dispatch_prepared(issue, settings)
    end
  end

  defp dispatch_prepared(issue, settings) do
    with :ok <- ExecutionReadiness.intake_open(settings),
         {:ok, _} <- ExecutionReadiness.prepare(issue, settings, []),
         do: :ok
  end

  @spec run(map(), pid() | nil, map(), keyword()) :: :ok
  def run(issue, recipient, settings, opts \\ []) do
    with :ok <- validate_runtime(Config.settings!(), settings),
         :ok <- Maintenance.open(settings),
         {:ok, file, prepared, resuming} <- admission(issue, settings, opts) do
      execute_claimed(issue, recipient, settings, file, opts, prepared, resuming)
    else
      {:error, reason} -> block(issue, recipient, reason)
      false -> block(issue, recipient, :issue_not_ready)
    end
  end

  defp admission(issue, settings, opts) do
    if Receipt.exists?(settings, issue) do
      with {:ok, models} <- resume_models(issue, settings, opts), do: {:ok, Receipt.path(settings, issue), models, true}
    else
      with :ok <- ExecutionReadiness.intake_open(settings),
           true <- Intake.ready?(issue, settings.ready_label),
           {:ok, prepared} <- ExecutionReadiness.prepare(issue, settings, opts),
           :ok <- ExecutionReadiness.intake_open(settings),
           :ok <- Maintenance.open(settings),
           {:ok, file} <- Receipt.claim(settings, issue) do
        {:ok, file, prepared, false}
      end
    end
  end

  defp resume_models(issue, settings, opts) do
    file = Receipt.path(settings, issue)

    if RestartRecovery.eligible?(file, settings) do
      receipt = Receipt.read(file)
      models = %{coder: receipt["models"]["coder"], reviewer: receipt["models"]["reviewer"], services: receipt["services"]}

      with :ok <- restart_authorization(file, issue, settings, opts),
           {:ok, report} <- ExecutionReadiness.check(settings, models, opts),
           :ok <- Maintenance.open(settings),
           do: {:ok, Map.put(models, :readiness, report)}
    else
      {:error, :mvp_receipt_exists}
    end
  end

  defp restart_authorization(file, issue, settings, opts) do
    case Intake.authorize_claimed(issue, settings, opts) do
      {:error, {:unauthorized_ready_actor, _}} = error ->
        RestartRecovery.stop(file, issue, settings, error)

      {:error, reason} = error when reason in [:issue_not_ready, :ready_label_event_not_found] ->
        RestartRecovery.stop(file, issue, settings, error)

      result ->
        result
    end
  end

  @spec block(map(), pid() | nil, term()) :: :ok
  def block(issue, recipient, reason) do
    Logger.warning("MVP waiting for operator issue_id=#{issue.id} reason=#{inspect(reason)}")

    if is_pid(recipient) do
      send(recipient, {:codex_worker_update, issue.id, %{event: :turn_input_required, timestamp: DateTime.utc_now(), message: inspect(reason)}})
    end

    :ok
  end

  @doc false
  @spec validate_runtime(map()) :: :ok | {:error, term()}
  def validate_runtime(config \\ Config.settings!()), do: validate_runtime(config, %{})

  @spec validate_runtime(map(), map()) :: :ok | {:error, term()}
  def validate_runtime(config, settings) do
    if config.tracker.kind in ["github", "gitlab"] and config.agent.max_concurrent_agents == 1 and
         config.worker.ssh_hosts == [] and match?({:unix, _}, :os.type()) and
         sandbox_policy?(config.codex, settings) do
      :ok
    else
      {:error, :mvp_requires_github_serial_local_linux_and_default_sandbox}
    end
  end

  defp sandbox_policy?(codex, settings) do
    if ExecutionReadiness.vm?(settings) do
      ExecutionReadiness.backend_ready?(settings) and codex.approval_policy == "never" and
        codex.thread_sandbox == "danger-full-access" and codex.turn_sandbox_policy == %{"type" => "dangerFullAccess"}
    else
      codex.thread_sandbox == "workspace-write" and is_nil(codex.turn_sandbox_policy) and is_map(codex.approval_policy)
    end
  end

  defp prepared_models(nil, issue, settings, opts) do
    with {:ok, models} <- Intake.resolve(issue, settings, opts), {:ok, services} <- ModelServices.freeze(models, settings), do: {:ok, Map.put(models, :services, services)}
  end

  defp prepared_models(models, _issue, _settings, _opts), do: {:ok, models}

  defp execute_claimed(issue, recipient, settings, file, opts, prepared, resuming) do
    tracker = Tracker.bind_agent_tools().tracker_settings

    handler = fn message ->
      if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue.id, message})
      :ok
    end

    options = opts |> Keyword.put(:tracker_settings, tracker) |> Keyword.put(:ready_label, settings.ready_label) |> Keyword.put(:on_message, handler)

    result =
      with {:ok, models} <- prepared_models(prepared, issue, settings, options),
           :ok <- freeze_claim(file, issue, settings, models, resuming),
           {:ok, workspace} <- claim_workspace(issue, settings, resuming) do
        if is_pid(recipient), do: send(recipient, {:worker_runtime_info, issue.id, %{worker_host: nil, workspace_path: workspace}})

        execute_workspace(workspace, issue, settings, models, file, options, resuming)
      end

    case result do
      {:ok, url} ->
        block(issue, recipient, {:awaiting_human_merge, url})

      {:error, reason} ->
        unless resuming or Receipt.read(file)["status"] in @preserved_failure_statuses, do: Receipt.update(file, "blocked", %{"reason" => inspect(reason)})
        block(issue, recipient, reason)
    end
  rescue
    exception ->
      unless resuming or Receipt.read(file)["status"] in @preserved_failure_statuses, do: Receipt.update(file, "blocked", %{"reason" => Exception.message(exception)})
      block(issue, recipient, {:mvp_failed, Exception.message(exception)})
  end

  defp execute_workspace(workspace, issue, settings, models, file, options, true),
    do: RestartRecovery.resume(workspace, issue, settings, models, file, options)

  defp execute_workspace(workspace, issue, settings, models, file, options, false) do
    with :ok <- Workspace.run_before_run_hook(workspace, issue, nil) do
      Executor.run(workspace, issue, settings, models, file, options)
    end
  after
    Workspace.run_after_run_hook(workspace, issue, nil)
  end

  defp claim_workspace(issue, _settings, false), do: Workspace.create_for_issue(issue, nil)

  defp claim_workspace(issue, settings, true) do
    workspace = Path.join(settings.execution_workspace_root, Workspace.workspace_key(issue))
    {:ok, workspace}
  end

  defp freeze_claim(_file, _issue, _settings, _models, true), do: :ok

  defp freeze_claim(file, issue, settings, models, false) do
    with :ok <- Receipt.update(file, "preparing", %{"models" => Map.take(models, [:coder, :reviewer]), "services" => models.services, "execution_readiness" => Map.get(models, :readiness)}),
         do: RestartRecovery.freeze(file, issue, settings, models)
  end
end
