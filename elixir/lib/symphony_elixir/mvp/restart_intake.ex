defmodule SymphonyElixir.Mvp.RestartIntake do
  @moduledoc "Reconcile opted-in interrupted receipts before the existing scheduler considers new work."

  alias SymphonyElixir.Mvp.{Intake, Maintenance, Receipt, RestartRecovery}

  @spec refresh([map()], map(), map(), ([String.t()] -> term())) :: {:ok, [map()]} | {:error, term()}
  def refresh(issues, settings, tracker, fetcher) do
    if RestartRecovery.enabled?(settings) and Maintenance.open(settings) == :ok do
      with {:ok, pending} <- pending(settings, tracker),
           :ok <- owners_dead(pending) do
        reconcile(issues, pending, settings, tracker, fetcher)
      end
    else
      {:ok, issues}
    end
  end

  defp pending(settings, tracker) do
    settings.state_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\.json\z/, Path.basename(&1)))
    |> Enum.reduce_while({:ok, []}, &pending_file(&1, &2, settings, tracker))
  end

  defp pending_file(path, {:ok, files}, settings, tracker) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, raw} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(raw) do
      selected = in_scope?(data, tracker) and RestartRecovery.pending?(path, settings)
      {:cont, {:ok, if(selected, do: files ++ [{path, data}], else: files)}}
    else
      _ -> {:halt, {:error, :mvp_restart_scan_unreadable}}
    end
  end

  defp in_scope?(data, tracker) do
    provider = tracker.provider
    repo = provider["repo"] || provider["project_path"]

    data["repository"] == repo and data["tracker_kind"] == tracker.kind and
      (tracker.kind != "gitlab" or data["tracker_api_url"] == provider["api_url"])
  end

  defp owners_dead(pending) do
    Enum.reduce_while(pending, :ok, fn {_path, data}, :ok ->
      case RestartRecovery.owner_dead(data["restart_recovery"]["owner"]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mvp_restart_intake_fenced, reason}}}
      end
    end)
  end

  defp reconcile(issues, [], _settings, _tracker, _fetcher), do: {:ok, issues}

  defp reconcile(issues, pending, settings, tracker, fetcher) do
    ids = Enum.map(pending, fn {_path, data} -> data["issue"] end)

    with {:ok, fresh} <- fetcher.(ids),
         :ok <- reconcile_authorization(pending, fresh, settings, tracker) do
      resumable = Enum.filter(fresh, &RestartRecovery.pending?(Receipt.path(settings, &1), settings))
      {:ok, if(resumable == [], do: issues, else: Enum.uniq_by(resumable, & &1.id))}
    end
  end

  defp reconcile_authorization(pending, fresh, settings, tracker) do
    Enum.reduce_while(pending, :ok, fn {path, data}, :ok ->
      case Enum.find(fresh, &(&1.id == data["issue"])) do
        nil -> {:halt, {:error, :mvp_restart_issue_unavailable}}
        issue -> reconcile_issue(path, issue, settings, tracker)
      end
    end)
  end

  defp reconcile_issue(path, issue, settings, tracker) do
    if Intake.ready?(issue, settings.ready_label) and issue.state in tracker.active_states do
      {:cont, :ok}
    else
      result = RestartRecovery.stop(path, issue, settings, {:error, :mvp_restart_ready_revoked})

      if File.exists?(path <> ".restart-blocked.json"), do: {:cont, :ok}, else: {:halt, result}
    end
  end
end
