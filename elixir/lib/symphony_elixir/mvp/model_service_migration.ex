defmodule SymphonyElixir.Mvp.ModelServiceMigration do
  @moduledoc "Audited enrichment of terminal receipts from explicit historical routing, never current defaults."

  alias SymphonyElixir.Mvp.{ModelCatalog, ModelServices, OperatorRecheck, Receipt}
  alias SymphonyElixir.PathSafety

  @roles ~w(coder reviewer)
  @effective ~w(provider adapter model parameters connection credential_ref command)
  @request ~w(id authorization runtime_version command predecessor legacy_closures receipt_sha256 historical_config services)

  @spec migrate(map(), Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def migrate(settings, receipt, request) do
    with true <- is_map(request) and Map.keys(request) -- @request == [],
         {:ok, canonical} <- PathSafety.canonicalize(receipt),
         true <- canonical == Path.expand(receipt) and Path.dirname(canonical) == Path.expand(settings.state_dir),
         {:ok, raw} <- File.read(receipt),
         true <- digest(raw) == request["receipt_sha256"],
         {:ok, data} <- Jason.decode(raw),
         true <- data["status"] in ["blocked", "awaiting_external"] and is_nil(data["services"]) and is_nil(data["model_service_migration"]),
         true <- is_list(data["rounds"]) and data["rounds"] != [],
         true <- Enum.all?(data["rounds"], &is_nil(&1["services"])),
         {:ok, historical} <- historical_config(request["historical_config"]),
         {:ok, services} <- validate_services(settings, request, data, historical),
         context = migration_context(receipt, data),
         audit = request |> Map.put("services", services) |> Map.put("kind", "model_service_migration"),
         {:ok, operation} <- OperatorRecheck.begin(context, raw, data, audit) do
      :ok =
        Receipt.update(receipt, data["status"], %{
          "services" => services,
          "model_service_migration" => operation.id,
          "operator_recheck" => operation.id
        })

      :ok = OperatorRecheck.complete(operation, {:ok, :model_service_migrated})
      {:ok, %{"id" => operation.id, "services" => services}}
    else
      _ -> {:error, :model_service_migration_refused}
    end
  rescue
    _ -> {:error, :model_service_migration_refused}
  end

  defp migration_context(receipt, data) do
    %{
      receipt: receipt,
      evidence: receipt <> ".evidence",
      settings: %{checks: hd(data["rounds"])["checks"]},
      issue: %{id: data["issue"]}
    }
  end

  defp historical_config(%{"path" => path, "sha256" => sha} = reference) when map_size(reference) == 2 do
    with {:ok, raw} <- File.read(path), true <- digest(raw) == sha, {:ok, value} <- Jason.decode(raw), true <- is_map(value) and Enum.sort(Map.keys(value)) == @roles do
      {:ok, value}
    end
  end

  defp historical_config(_), do: {:error, :historical_config_missing}

  defp validate_services(settings, request, data, historical) do
    services = request["services"]

    with true <- is_map(services) and Enum.sort(Map.keys(services)) == @roles,
         {:ok, registry} <- ModelServices.load(ModelServices.path(settings), settings.model_services),
         true <- is_map(registry) do
      validate_roles(services, request, data, historical, registry)
    end
  end

  defp validate_roles(services, request, data, historical, registry) do
    Enum.reduce_while(@roles, {:ok, %{}}, fn role, {:ok, verified} ->
      case validate_role_service(services[role], role, request, data, historical, registry) do
        {:ok, service} -> {:cont, {:ok, Map.put(verified, role, service)}}
        _ -> {:halt, {:error, :invalid_historical_service}}
      end
    end)
  end

  defp validate_role_service(service, role, request, data, historical, registry) do
    with :ok <- ModelServices.validate_snapshot(service),
         true <- service["role"] == role and service["model"] == data["models"][role],
         true <- historical[role] == Map.take(service, @effective),
         true <- service["source"] == "historical_migration:" <> request["id"],
         :ok <- ModelServices.credential_boundary(service, [data["workspace"], context_evidence(data)]),
         :ok <- ModelCatalog.available(registry, service) do
      {:ok, Map.put(service, "capability_evidence", registry["validations"][ModelServices.binding(service)])}
    end
  end

  defp context_evidence(data), do: hd(data["rounds"])["evidence"] |> Path.dirname()

  @doc "Resolve unchanged historical round/handoff records through their audited before-receipt."
  @spec services(map(), map(), Path.t()) :: {:ok, map() | nil} | {:error, atom()}
  def services(data, record, receipt) do
    cond do
      record["services"] == data["services"] -> {:ok, data["services"]}
      is_nil(record["services"]) and is_binary(data["model_service_migration"]) -> migrated_services(data, record, receipt)
      true -> {:error, :frozen_services_mismatch}
    end
  end

  defp migrated_services(data, record, receipt) do
    id = data["model_service_migration"]

    with true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/, id),
         directory = Path.join([receipt <> ".evidence", "operator-rechecks", id]),
         {:ok, audit_raw} <- File.read(Path.join(directory, "authorization.json")),
         {:ok, audit} <- Jason.decode(audit_raw),
         true <- is_map(audit),
         true <- audit["kind"] == "model_service_migration" and audit["services"] == data["services"],
         {:ok, before_raw} <- File.read(Path.join(directory, "receipt-before.json")),
         true <- digest(before_raw) == audit["receipt_sha256"],
         {:ok, before} <- Jason.decode(before_raw),
         true <- is_map(before),
         true <- is_nil(before["services"]) and before["models"] == data["models"],
         records = (before["rounds"] || []) ++ List.wrap(before["external_handoff"]),
         true <- Enum.any?(records, &(Map.drop(&1, ~w(record_path record_sha256)) == record)) do
      {:ok, data["services"]}
    else
      _ -> {:error, :model_service_migration_audit_mismatch}
    end
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
