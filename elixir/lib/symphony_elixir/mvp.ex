defmodule SymphonyElixir.Mvp do
  @moduledoc "Opt-in finite delivery gate inside the upstream worker lifecycle."

  require Logger
  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Mvp.{Executor, Intake, Receipt}

  @preserved_failure_statuses ["publish_pending", "comment_pending", "awaiting_external"]

  @spec available?(map()) :: boolean()
  def available?(issue) do
    case Config.mvp_settings() do
      {:ok, %{enabled: false, configured: false}} -> true
      {:ok, %{enabled: false}} -> false
      {:ok, settings} -> Intake.ready?(issue, settings.ready_label) and not Receipt.exists?(settings, issue)
      {:error, _} -> false
    end
  end

  @spec run(map(), pid() | nil, map(), keyword()) :: :ok
  def run(issue, recipient, settings, opts \\ []) do
    with :ok <- validate_runtime(),
         true <- Intake.ready?(issue, settings.ready_label),
         {:ok, file} <- Receipt.claim(settings, issue) do
      execute_claimed(issue, recipient, settings, file, opts)
    else
      {:error, reason} -> block(issue, recipient, reason)
      false -> block(issue, recipient, :issue_not_ready)
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
  def validate_runtime(config \\ Config.settings!()) do
    if config.tracker.kind == "github" and config.agent.max_concurrent_agents == 1 and
         config.worker.ssh_hosts == [] and match?({:unix, _}, :os.type()) and
         config.codex.thread_sandbox == "workspace-write" and
         is_nil(config.codex.turn_sandbox_policy) and is_map(config.codex.approval_policy) do
      :ok
    else
      {:error, :mvp_requires_github_serial_local_linux_and_default_sandbox}
    end
  end

  defp execute_claimed(issue, recipient, settings, file, opts) do
    tracker = Tracker.bind_agent_tools().tracker_settings

    handler = fn message ->
      if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue.id, message})
      :ok
    end

    options = opts |> Keyword.put(:tracker_settings, tracker) |> Keyword.put(:ready_label, settings.ready_label) |> Keyword.put(:on_message, handler)

    result =
      with {:ok, models} <- Intake.resolve(issue, settings, options),
           :ok <- Receipt.update(file, "preparing", %{"models" => models}),
           {:ok, workspace} <- Workspace.create_for_issue(issue, nil) do
        if is_pid(recipient), do: send(recipient, {:worker_runtime_info, issue.id, %{worker_host: nil, workspace_path: workspace}})

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, nil) do
            Executor.run(workspace, issue, settings, models, file, options)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, nil)
        end
      end

    case result do
      {:ok, url} ->
        block(issue, recipient, {:awaiting_human_merge, url})

      {:error, reason} ->
        unless Receipt.read(file)["status"] in @preserved_failure_statuses, do: Receipt.update(file, "blocked", %{"reason" => inspect(reason)})
        block(issue, recipient, reason)
    end
  rescue
    exception ->
      unless Receipt.read(file)["status"] in @preserved_failure_statuses, do: Receipt.update(file, "blocked", %{"reason" => Exception.message(exception)})
      block(issue, recipient, {:mvp_failed, Exception.message(exception)})
  end
end
