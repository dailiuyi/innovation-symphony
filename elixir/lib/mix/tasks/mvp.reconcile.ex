defmodule Mix.Tasks.Mvp.Reconcile do
  @moduledoc "Match an uncertain delivery to a GitHub PR without republishing."
  use Mix.Task
  alias SymphonyElixir.{Config, Workflow, WorkflowStore}
  alias SymphonyElixir.Mvp.Delivery

  @shortdoc "Reconcile one durable receipt (GitHub reads only)"
  @impl Mix.Task
  def run(args), do: reconcile(args, &Delivery.reconcile/2)

  @doc false
  @spec reconcile([String.t()], (Path.t(), keyword() -> term())) :: :ok | no_return()
  def reconcile([workflow, receipt], reconcile_fun) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)
    Workflow.set_workflow_file_path(Path.expand(workflow))

    case WorkflowStore.force_reload() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Invalid workflow: #{inspect(reason)}")
    end

    tracker = Config.settings!().tracker

    case reconcile_fun.(Path.expand(receipt), tracker_settings: tracker) do
      {:ok, url} -> Mix.shell().info("Matched: #{url}; human merge/upgrade still required.")
      {:error, reason} -> Mix.raise("Still unresolved: #{inspect(reason)}. Receipt retained; no writes sent to GitHub.")
    end
  end

  def reconcile(_, _), do: Mix.raise("Usage: mix mvp.reconcile WORKFLOW.md RECEIPT.json")
end
