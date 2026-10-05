defmodule Mix.Tasks.Mvp.Models do
  @moduledoc "Local administrator model-service registry; never starts the scheduler or writes View data."
  use Mix.Task

  alias SymphonyElixir.Mvp.{Config, ModelCatalog, ModelServices}
  alias SymphonyElixir.{Workflow, WorkflowStore}

  @shortdoc "Read, save, discover or verify controlled role model services"
  @impl Mix.Task
  def run([action, workflow | args]) do
    with {:ok, loaded} <- Workflow.load(Path.expand(workflow)),
         {:ok, settings} <- Config.settings(loaded, Path.dirname(Path.expand(workflow))),
         :ok <- Workflow.set_workflow_file_path(Path.expand(workflow)),
         :ok <- WorkflowStore.force_reload(),
         result <- execute(action, settings, args) do
      case result do
        {:ok, value} -> Mix.shell().info(Jason.encode!(value, pretty: true))
        {:error, reason} -> Mix.raise("Model service operation refused: #{safe_reason(reason)}. Existing configuration retained.")
      end
    else
      _ -> Mix.raise("Cannot load model service configuration.")
    end
  end

  def run(_), do: Mix.raise("Usage: mix mvp.models show|save|refresh|register|attest|verify WORKFLOW.md [arguments]")

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_), do: "invalid_model_service_operation"

  @doc false
  @spec execute(String.t(), map(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def execute(action, settings, args) do
    if is_map(Map.get(settings, :model_services)) and is_binary(Map.get(settings, :state_dir)), do: operation(action, settings, args), else: {:error, :model_services_not_configured}
  end

  defp operation("show", settings, []), do: ModelServices.read(settings)

  defp operation("save", settings, [revision, input]) do
    with {expected, ""} when expected >= 0 <- Integer.parse(revision),
         {:ok, raw} <- File.read(input),
         {:ok, proposed} <- Jason.decode(raw),
         {:ok, _} <- ModelServices.save(ModelServices.path(settings), settings.model_services, expected, proposed, settings.model_command) do
      ModelServices.read(settings)
    else
      _ -> {:error, :model_services_save_failed}
    end
  end

  defp operation("refresh", settings, [id]), do: persist(settings, ModelCatalog.refresh(settings, id))

  defp operation("register", settings, [id, model | efforts]),
    do: persist(settings, ModelCatalog.register(settings.model_services, id, model, efforts))

  defp operation("attest", settings, [id, model, role, input]) when role in ["coder", "reviewer"] do
    with {:ok, raw} <- File.read(input), {:ok, proof} <- Jason.decode(raw), {:ok, template} <- ModelServices.snapshot(settings, id, String.to_existing_atom(role), "manual_validation") do
      persist(settings, ModelCatalog.attest(settings.model_services, Map.put(template, "model", model), proof))
    end
  end

  defp operation("verify", settings, [id, model, role, workspace]) when role in ["coder", "reviewer"],
    do: persist(settings, ModelCatalog.verify(settings, id, model, String.to_existing_atom(role), workspace))

  defp operation(_, _, _), do: {:error, :invalid_model_service_command}

  defp persist(settings, {:error, {:model_discovery_failed, registry}}) do
    case persist(settings, {:ok, registry}) do
      {:ok, _} -> {:error, :model_discovery_failed}
      error -> error
    end
  end

  defp persist(settings, {:ok, registry}) do
    with {:ok, _} <- ModelServices.save(ModelServices.path(settings), settings.model_services, settings.model_services["revision"], registry, settings.model_command),
         do: ModelServices.read(settings)
  end

  defp persist(_, error), do: error
end
