defmodule SymphonyElixir.Mvp.RestartRecovery do
  @moduledoc "Explicit new-task restart contracts. An unknown owner or model outcome never grants a retry."

  alias SymphonyElixir.Mvp.{Attempts, Commands, Executor, ExternalHandoff, Intake, Receipt, Recovery}
  alias SymphonyElixir.{PathSafety, Workspace}

  @statuses ~w(claimed preparing coding checking reviewing recovering publish_pending comment_pending)
  @setting_keys ~w(checks check_timeout_ms recovery sandbox execution_readiness execution_workspace_root state_dir model_command max_rework ready_label allowed_actors allowed_models)a

  defguardp valid_owner_identity?(boot, machine, namespace, pid, start)
            when is_binary(boot) and byte_size(boot) > 0 and is_binary(machine) and
                   is_binary(namespace) and is_integer(pid) and pid > 0 and is_binary(start)

  @spec enabled?(map()) :: boolean()
  def enabled?(settings) do
    Recovery.enabled?(settings) and get_in(settings, [:recovery, :resume_on_restart]) == true and
      get_in(settings, [:execution_readiness, :enabled]) == true and
      get_in(settings, [:execution_readiness, :required_backend]) == "vm" and
      get_in(settings, [:sandbox, :enabled]) == false
  end

  @spec eligible?(Path.t(), map()) :: boolean()
  def eligible?(receipt, settings) do
    with {:ok, data} <- pending_receipt(receipt, settings),
         :ok <- owner_dead(data["restart_recovery"]["owner"]) do
      true
    else
      _ -> false
    end
  end

  @doc "Find explicit unfinished new-task contracts even when their owner is live or unverifiable."
  @spec pending?(Path.t(), map()) :: boolean()
  def pending?(receipt, settings), do: match?({:ok, _}, pending_receipt(receipt, settings))

  defp pending_receipt(receipt, settings) do
    with true <- enabled?(settings),
         false <- File.exists?(receipt <> ".restart-blocked.json"),
         {:ok, data} <- read(receipt),
         %{"enabled" => true, "schema" => 1, "owner" => _owner} <- data["restart_recovery"],
         true <- resumable_status?(data) do
      {:ok, data}
    else
      _ -> {:error, :mvp_restart_not_pending}
    end
  end

  defp resumable_status?(%{"status" => "blocked", "rounds" => rounds} = data) when is_list(rounds) do
    is_nil(data["reason"]) and
      case List.last(rounds) do
        %{"review" => %{"approved" => false}, "comment" => %{"id" => id}} when is_integer(id) and id > 0 -> true
        _ -> false
      end
  end

  defp resumable_status?(data), do: data["status"] in @statuses

  @doc "Keep a scoped terminal restart stop alongside the unchanged receipt, including its raw bytes."
  @spec stop(Path.t(), map(), map(), term()) :: term()
  def stop(receipt, issue, settings, {:error, reason} = result) do
    with true <- receipt == Receipt.path(settings, issue),
         {:ok, %{type: :regular}} <- File.lstat(receipt),
         {:ok, raw} <- File.read(receipt),
         {:ok, %{"restart_recovery" => %{"enabled" => true, "owner" => owner}}} <- Jason.decode(raw),
         true <- owner_dead(owner) == :ok or owner_matches_current?(owner) do
      journal = %{
        "schema" => 1,
        "status" => "blocked",
        "reason" => inspect(reason),
        "receipt_sha256" => digest(raw),
        "receipt_before" => raw,
        "stopped_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      case File.write(receipt <> ".restart-blocked.json", Jason.encode!(journal, pretty: true), [:exclusive, :sync]) do
        :ok -> result
        {:error, :eexist} -> result
        {:error, error} -> {:error, {:mvp_restart_stop_write, error}}
      end
    else
      _ -> result
    end
  end

  def stop(_receipt, _issue, _settings, result), do: result

  defp owner_matches_current?(expected) do
    owner() == {:ok, expected}
  end

  @doc "Freeze once, before workspace creation/hooks. Old or disabled receipts cannot be upgraded implicitly."
  @spec freeze(Path.t(), map(), map(), map()) :: :ok | {:error, term()}
  def freeze(receipt, issue, settings, models) do
    if enabled?(settings) do
      data = Receipt.read(receipt)

      with true <- data["status"] in ~w(claimed preparing) and is_nil(data["base_sha"]) and is_nil(data["restart_recovery"]),
           true <- receipt == Receipt.path(settings, issue),
           {:ok, owner} <- owner() do
        contract = %{
          "schema" => 1,
          "enabled" => true,
          "owner" => owner,
          "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "issue" => issue_json(issue),
          "settings" => settings_json(settings),
          "models" => models_json(models),
          "workspace" => Path.join(settings.execution_workspace_root, Workspace.workspace_key(issue)),
          "source_sha256" => source_digest(),
          "generation" => 0
        }

        Receipt.update(receipt, data["status"], %{"restart_recovery" => contract, "models" => Map.take(models, [:coder, :reviewer]), "services" => models[:services]})
      else
        _ -> {:error, :mvp_restart_freeze_invalid}
      end
    else
      :ok
    end
  end

  @spec resume(Path.t(), map(), map(), map(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume(workspace, issue, settings, models, receipt, opts \\ []) do
    Executor.resume_restart(workspace, issue, settings, models, receipt, opts)
  end

  @doc "Read-only binding check, repeated inside the OS lock before any continuation effects."
  @spec validate(Path.t(), map(), map(), map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def validate(workspace, issue, settings, models, receipt) do
    with true <- eligible?(receipt, settings),
         true <- Intake.ready?(issue, settings.ready_label) or {:error, :mvp_restart_issue_not_ready},
         {:ok, data} <- read(receipt),
         frozen = data["restart_recovery"],
         true <- receipt == Receipt.path(settings, issue),
         true <- frozen["issue"] == issue_json(issue),
         true <- frozen["settings"] == settings_json(settings),
         true <- frozen["models"] == models_json(models),
         true <- frozen["source_sha256"] == source_digest(),
         true <- data["issue"] == issue.id and data["repository"] == issue.native_ref["repo"],
         true <- data["issue_native_ref"] == issue.native_ref,
         true <- workspace == frozen["workspace"],
         :ok <- workspace_scope(workspace, settings),
         :ok <- preparation_binding(workspace, frozen["preparation"]),
         :ok <- checkpoint_binding(workspace, frozen["checkpoint"]) do
      {:ok, data}
    else
      {:error, _} = error -> error
      _ -> {:error, :mvp_restart_binding_invalid}
    end
  end

  @spec adopt(Path.t(), map()) :: :ok | {:error, term()}
  def adopt(receipt, data) do
    with {:ok, current} <- owner() do
      frozen = data["restart_recovery"]
      history = Map.get(frozen, "owners", []) ++ [frozen["owner"]]
      frozen = Map.merge(frozen, %{"owner" => current, "owners" => history, "generation" => frozen["generation"] + 1})
      Receipt.update(receipt, data["status"], %{"restart_recovery" => frozen})
    end
  end

  @doc "OS flock survives concurrent controllers and is released by the kernel when its holder exits."
  @spec locked(Path.t(), (-> term())) :: term()
  def locked(receipt, fun) do
    case System.find_executable("flock") do
      nil ->
        {:error, :mvp_restart_lock_unavailable}

      flock ->
        port = Port.open({:spawn_executable, flock}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: ["--nonblock", receipt <> ".restart.lock", "cat"]])
        Port.command(port, "restart-locked\n")

        try do
          receive do
            {^port, {:data, "restart-locked\n"}} -> fun.()
            {^port, {:exit_status, _}} -> {:error, :mvp_restart_active}
          after
            5_000 -> {:error, :mvp_restart_lock_unavailable}
          end
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  end

  @spec checkpoint(map(), map()) :: :ok
  def checkpoint(context, extra \\ %{}) do
    data = Receipt.read(context.receipt)
    fields = checkpoint_fields(context, extra)
    if fields != %{}, do: Receipt.update(context.receipt, data["status"], fields), else: :ok
  end

  @spec checkpoint_fields(map(), map()) :: map()
  def checkpoint_fields(context, extra \\ %{}) do
    data = Receipt.read(context.receipt)

    case data["restart_recovery"] do
      %{"enabled" => true} = frozen ->
        {:ok, digest} = Executor.workspace_digest(context.workspace)
        {:ok, metadata} = ExternalHandoff.encode_git_metadata(context.metadata)
        {:ok, identity} = workspace_identity(context.workspace)

        checkpoint = %{
          "workspace" => context.workspace,
          "identity" => identity,
          "workspace_sha256" => digest,
          "base_sha" => context.base,
          "branch" => context.branch,
          "repository" => context.repository,
          "metadata" => metadata,
          "baseline_sha256" => Base.encode16(context.baseline_digest, case: :lower),
          "head" => Commands.git!(["rev-parse", "HEAD"], context.workspace),
          "status" => data["status"]
        }

        prior = Map.take(frozen["checkpoint"] || %{}, ["feedback", "coding_head"])
        checkpoint = prior |> Map.merge(checkpoint) |> Map.merge(extra)
        %{"restart_recovery" => Map.put(frozen, "checkpoint", json(checkpoint))}

      _ ->
        %{}
    end
  end

  @spec preparation(Path.t(), Path.t(), map()) :: :ok
  def preparation(receipt, workspace, fields) do
    data = Receipt.read(receipt)

    if is_map(data["restart_recovery"]) do
      {:ok, identity} = workspace_identity(workspace)
      previous = data["restart_recovery"]["preparation"] || %{}
      preparing = Map.merge(previous, Map.merge(%{"workspace" => workspace, "identity" => identity}, fields))
      frozen = Map.put(data["restart_recovery"], "preparation", preparing)
      Receipt.update(receipt, "preparing", %{"restart_recovery" => frozen})
    else
      :ok
    end
  end

  @spec budget(map(), map(), keyword()) :: :ok | {:error, atom()}
  def budget(data, settings, opts) do
    frozen = data["restart_recovery"]
    recovery = data["recovery"] || %{"started_at" => frozen["started_at"], "agent_attempts" => 0, "external_wait_ms" => 0}
    now = Keyword.get(opts, :now_ms, fn -> System.system_time(:millisecond) end).()
    count = recovery["agent_attempts"] + Map.get(data, "external_probe_calls", 0)

    if is_integer(count) and count <= settings.recovery.max_agent_attempts and
         Map.get(data, "rework_count", 0) <= settings.recovery.max_rework and
         Recovery.within_budget?(settings.recovery, recovery["started_at"], now, recovery["external_wait_ms"] || 0),
       do: :ok,
       else: {:error, :mvp_recovery_resource_exhausted}
  end

  @spec owner() :: {:ok, map()} | {:error, atom()}
  @spec owner((term() -> term())) :: {:ok, map()} | {:error, atom()}
  def owner(observe \\ &observe/1) do
    with {:ok, boot} <- observe.(:boot),
         {:ok, machine} <- observe.(:machine),
         {:ok, namespace} <- observe.(:namespace),
         {pid, ""} <- Integer.parse(System.pid()),
         {:ok, start} <- process_start(pid, observe) do
      {:ok, %{"boot_id" => String.trim(boot), "machine_sha256" => digest(machine), "pid_namespace" => namespace, "pid" => pid, "starttime" => start}}
    else
      _ -> {:error, :mvp_restart_owner_unknown}
    end
  end

  @spec owner_dead(term()) :: :ok | {:error, atom()}
  def owner_dead(previous, observe \\ &observe/1)

  @spec owner_dead(term(), (term() -> term())) :: :ok | {:error, atom()}
  def owner_dead(%{"boot_id" => boot, "machine_sha256" => machine, "pid_namespace" => namespace, "pid" => pid, "starttime" => start} = previous, observe)
      when valid_owner_identity?(boot, machine, namespace, pid, start) do
    with {:ok, current} <- owner(observe),
         true <- current["machine_sha256"] == machine do
      owner_liveness(previous, current, observe)
    else
      _ -> {:error, :mvp_restart_owner_unknown}
    end
  end

  def owner_dead(_, _), do: {:error, :mvp_restart_owner_unknown}

  defp owner_liveness(previous, current, observe) do
    cond do
      previous["boot_id"] != current["boot_id"] -> :ok
      previous["pid_namespace"] != current["pid_namespace"] -> {:error, :mvp_restart_owner_unknown}
      true -> owner_process_liveness(previous["pid"], previous["starttime"], observe)
    end
  end

  defp owner_process_liveness(pid, start, observe) do
    case process_start(pid, observe) do
      {:ok, ^start} -> {:error, :mvp_restart_active}
      {:ok, _different} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :mvp_restart_owner_unknown}
    end
  end

  defp process_start(pid, observe) do
    with {:ok, stat} <- observe.({:stat, pid}),
         [fields] <- Regex.run(~r/\A\d+ \(.*\) (.*)\z/s, String.trim(stat), capture: :all_but_first),
         value when is_binary(value) <- fields |> String.split() |> Enum.at(19),
         {_number, ""} <- Integer.parse(value) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_stat}
    end
  end

  defp observe(:boot), do: File.read("/proc/sys/kernel/random/boot_id")
  defp observe(:machine), do: File.read("/etc/machine-id")
  defp observe(:namespace), do: File.read_link("/proc/self/ns/pid")
  defp observe({:stat, pid}), do: File.read("/proc/#{pid}/stat")

  defp workspace_scope(workspace, settings) do
    with {:ok, canonical} <- PathSafety.canonicalize(workspace),
         {:ok, root} <- PathSafety.canonicalize(settings.execution_workspace_root),
         true <- canonical == Path.expand(workspace) and String.starts_with?(canonical, root <> "/") do
      :ok
    else
      _ -> {:error, :mvp_restart_workspace_invalid}
    end
  end

  defp preparation_binding(_workspace, nil), do: :ok

  defp preparation_binding(workspace, preparation) do
    with true <- preparation["workspace"] == workspace,
         {:ok, identity} <- workspace_identity(workspace),
         true <- identity == preparation["identity"] do
      :ok
    else
      _ -> {:error, :mvp_restart_workspace_changed}
    end
  end

  defp checkpoint_binding(_workspace, nil), do: :ok

  defp checkpoint_binding(workspace, checkpoint) do
    with true <- checkpoint["workspace"] == workspace,
         {:ok, identity} <- workspace_identity(workspace),
         true <- identity == checkpoint["identity"],
         {:ok, digest} <- Executor.workspace_digest(workspace),
         true <- digest == checkpoint["workspace_sha256"] or checkpoint["status"] == "coding" do
      :ok
    else
      _ -> {:error, :mvp_restart_workspace_changed}
    end
  end

  defp workspace_identity(path) do
    with {:ok, %{type: :directory} = stat} <- File.lstat(path),
         {:ok, %{type: :directory} = git} <- File.lstat(Path.join(path, ".git")) do
      {:ok, %{"inode" => stat.inode, "major_device" => stat.major_device, "minor_device" => stat.minor_device, "git_inode" => git.inode, "git_device" => git.major_device}}
    else
      _ -> {:error, :mvp_restart_workspace_invalid}
    end
  end

  defp read(path) do
    with {:ok, raw} <- File.read(path), {:ok, data} when is_map(data) <- Jason.decode(raw), do: {:ok, data}
  end

  defp issue_json(issue), do: issue |> Map.take(~w(id identifier title description native_ref)a) |> json()
  defp settings_json(settings), do: settings |> Map.take(@setting_keys) |> json()
  defp models_json(models), do: models |> Map.take(~w(coder reviewer services)a) |> json()
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp source_digest do
    [__MODULE__, Executor, Attempts, Recovery]
    |> Enum.map(&{&1, &1.module_info(:md5)})
    |> :erlang.term_to_binary([:deterministic])
    |> digest()
  end
end
