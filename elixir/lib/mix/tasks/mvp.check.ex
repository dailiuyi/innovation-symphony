defmodule Mix.Tasks.Mvp.Check do
  @moduledoc "Validate a workflow without starting the scheduler or contacting providers."
  use Mix.Task
  alias SymphonyElixir.{Config, Workflow, WorkflowStore}

  @shortdoc "Check local MVP configuration without dispatch"
  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.config")
    Workflow.set_workflow_file_path(Path.expand(path))

    with :ok <- WorkflowStore.force_reload(),
         {:ok, _} <- Config.settings(),
         {:ok, settings} <- Config.mvp_settings() do
      Mix.shell().info("Local configuration parsed; MVP enabled=#{settings.enabled}. No remote/model availability was checked.")
    else
      {:error, reason} -> Mix.raise("Invalid local configuration: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix mvp.check /absolute/path/WORKFLOW.md")
end
