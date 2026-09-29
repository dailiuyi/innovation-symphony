defmodule SymphonyElixir.Mvp.Preflight do
  @moduledoc "Read-only configuration and GitHub polling probe. Never starts the agent runtime."

  alias SymphonyElixir.{Config, Mvp, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.Config, as: MvpConfig

  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, opts \\ []) do
    path = Path.expand(path)
    fetch_issues = Keyword.get(opts, :fetch_issues, &Client.fetch_issues_by_states/2)

    with {:ok, workflow} <- Workflow.load(path),
         {:ok, config} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(config),
         {:ok, mvp} <- MvpConfig.settings(workflow, Path.dirname(path)),
         :ok <- require_enabled(mvp),
         :ok <- Mvp.validate_runtime(config),
         :ok <- require_active_states(config),
         {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, issues} <- fetch_issues.(config.tracker.active_states, config.tracker) do
      {:ok, %{mode: "preflight", status: "passed", issue_count: length(issues)}}
    end
  end

  defp require_enabled(%{enabled: true}), do: :ok
  defp require_enabled(_), do: {:error, :mvp_preflight_requires_enabled_workflow}

  # Config.validate_settings/1 already restricts GitHub active states to open.
  # Reject the empty list, which the client would otherwise return without a GET.
  defp require_active_states(%{tracker: %{active_states: [_ | _]}}), do: :ok
  defp require_active_states(_), do: {:error, :mvp_preflight_requires_active_states}
end
