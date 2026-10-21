defmodule SymphonyElixir.Mvp.Maintenance do
  @moduledoc "VM maintenance fence and serialized drain acknowledgement; active work keeps its authorization."

  alias SymphonyElixir.Mvp.Config, as: MvpConfig
  alias SymphonyElixir.Workflow

  @spec path(map()) :: Path.t()
  def path(settings), do: Path.join(settings.state_dir, "maintenance.json")

  @spec open(map()) :: :ok | {:error, atom()}
  def open(settings) do
    if vm?(settings) do
      case File.lstat(path(settings)) do
        {:error, :enoent} -> :ok
        _ -> {:error, :mvp_maintenance_paused}
      end
    else
      :ok
    end
  end

  @doc "Called only while the Orchestrator handles its serialized snapshot request."
  @spec current_snapshot(map()) :: map() | nil
  def current_snapshot(state) do
    path = Workflow.workflow_file_path()

    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- MvpConfig.settings(workflow, Path.dirname(path)) do
      snapshot(settings, state)
    else
      _ -> nil
    end
  end

  @spec snapshot(map(), map()) :: map() | nil
  def snapshot(settings, state) do
    if open(settings) == :ok do
      nil
    else
      with {:ok, %{type: :regular, size: size}} when size <= 4096 <- File.lstat(path(settings)),
           {:ok, raw} <- File.read(path(settings)),
           {:ok, %{"nonce" => nonce}} <- Jason.decode(raw),
           true <- is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{32}\z/, nonce),
           {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
           {pid, ""} <- Integer.parse(System.pid()) do
        %{
          nonce: nonce,
          acknowledged: true,
          drained: drained?(state),
          pid: pid,
          boot_id: String.trim(boot)
        }
      else
        _ -> %{acknowledged: false, drained: false}
      end
    end
  end

  defp drained?(state) do
    map_size(state.running) == 0 and map_size(state.retry_attempts) == 0 and state.poll_check_in_progress != true
  end

  defp vm?(settings) do
    is_binary(settings[:state_dir]) and get_in(settings, [:execution_readiness, :enabled]) == true and
      get_in(settings, [:execution_readiness, :required_backend]) == "vm"
  end
end
