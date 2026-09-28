defmodule Mix.Tasks.Mvp.Release do
  @moduledoc "Release a blocked intake receipt before any coder or publication was started. Stop the runner first."
  use Mix.Task
  alias SymphonyElixir.Mvp.Receipt

  @shortdoc "Release a pre-coding failure receipt with the runner stopped"
  @impl Mix.Task
  def run([file]) do
    Mix.Task.run("app.config")
    data = Receipt.read(file)

    if data["status"] == "blocked" and is_nil(data["base_sha"]) and is_nil(data["candidate_sha"]) do
      archive = file <> ".released-" <> Integer.to_string(System.system_time(:microsecond))
      File.rename!(file, archive)
      Mix.shell().info("Archived pre-coding receipt: #{archive}. After correcting the cause, restart the runner. No remote write was made.")
    else
      Mix.raise("Not a pre-coding blocked receipt; inspect evidence and reconcile delivery before any new attempt.")
    end
  end

  def run(_), do: Mix.raise("Stop the runner first. Usage: mix mvp.release RECEIPT.json")
end
