defmodule SymphonyElixir.Mvp.ModelCatalog do
  @moduledoc "Account-specific discovery is distinct from expiring, role-specific inference evidence."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Mvp.{ExecutionSandbox, ModelServices}

  @spec valid?(term(), term()) :: boolean()
  def valid?(catalog, validations) do
    is_map(catalog) and is_map(validations) and
      Enum.all?(catalog, fn {id, entry} -> ModelServices.identifier?(id) and valid_catalog?(entry) end) and
      Enum.all?(validations, fn {binding, proof} ->
        is_binary(binding) and Regex.match?(~r/\A[0-9a-f]{64}\z/, binding) and valid_proof?(proof)
      end)
  end

  defp valid_catalog?(entry) when is_map(entry) do
    Map.keys(entry) -- ~w(models refreshed_at error) == [] and is_map(entry["models"]) and
      (is_nil(entry["refreshed_at"]) or timestamp?(entry["refreshed_at"])) and
      entry["error"] in [nil, "discovery_failed", "manual_catalog"] and
      Enum.all?(entry["models"], &valid_metadata?/1)
  end

  defp valid_catalog?(_), do: false

  defp valid_metadata?({model, metadata}) when is_map(metadata) do
    ModelServices.identifier?(model) and
      Enum.sort(Map.keys(metadata)) == Enum.sort(~w(reasoning_efforts disabled discovery)) and
      is_boolean(metadata["disabled"]) and is_list(metadata["reasoning_efforts"]) and
      valid_efforts?(metadata["reasoning_efforts"]) and valid_discovery?(metadata["discovery"])
  end

  defp valid_metadata?(_), do: false

  defp valid_efforts?(efforts), do: Enum.all?(efforts, &(&1 in ~w(none minimal low medium high xhigh)))

  defp valid_discovery?(discovery) when is_map(discovery) do
    Enum.all?(discovery, &valid_channel?/1)
  end

  defp valid_discovery?(_), do: false

  defp valid_channel?({channel, entry}) when is_map(entry) do
    is_binary(channel) and Regex.match?(~r/\A[0-9a-f]{64}\z/, channel) and
      Enum.sort(Map.keys(entry)) == Enum.sort(~w(discovered_at reasoning_efforts source)) and
      timestamp?(entry["discovered_at"]) and is_list(entry["reasoning_efforts"]) and
      valid_efforts?(entry["reasoning_efforts"]) and entry["source"] in ["manual", "appserver"]
  end

  defp valid_channel?(_), do: false

  defp valid_proof?(proof) when is_map(proof) do
    Enum.sort(Map.keys(proof)) == Enum.sort(~w(role validated_at expires_at capabilities actual_model source)) and
      proof["role"] in ~w(coder reviewer) and timestamp?(proof["validated_at"]) and timestamp?(proof["expires_at"]) and
      is_list(proof["capabilities"]) and Enum.all?(proof["capabilities"], &(&1 in ~w(tools structured_output))) and
      (is_nil(proof["actual_model"]) or ModelServices.identifier?(proof["actual_model"])) and
      proof["source"] in ~w(inference manual)
  end

  defp valid_proof?(_), do: false
  defp timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp timestamp?(_), do: false

  @spec available(map(), map()) :: :ok | {:error, atom()}
  def available(registry, service) do
    metadata = get_in(registry, ["catalog", service["id"], "models", service["model"]])
    effort = service["parameters"]["reasoning_effort"]

    with :ok <- ModelServices.identity_matches(service),
         :ok <- ModelServices.connection_ready(service),
         :ok <- supported_service(registry, service),
         :ok <- supported_metadata(metadata, effort, service) do
      verified_role(registry["validations"][ModelServices.binding(service)], service["role"])
    end
  end

  defp supported_service(registry, service) do
    cond do
      service["provider"] != "openai" or service["adapter"] != "codex_app_server" -> {:error, :model_provider_not_supported}
      not String.starts_with?(service["model"], "gpt-") -> {:error, :model_protocol_incompatible}
      not Map.has_key?(registry["presets"], service["id"]) -> {:error, :model_service_revoked}
      service["model"] in Map.get(registry, "disabled_models", []) -> {:error, :model_disabled}
      true -> :ok
    end
  end

  defp supported_metadata(nil, _, _), do: {:error, :model_not_discovered}

  defp supported_metadata(metadata, effort, service) do
    discovered = metadata["discovery"][ModelServices.channel_binding(service)]

    cond do
      metadata["disabled"] -> {:error, :model_disabled}
      is_nil(discovered) -> {:error, :model_catalog_channel_unverified}
      effort && effort not in discovered["reasoning_efforts"] -> {:error, :model_reasoning_effort_unsupported}
      true -> :ok
    end
  end

  defp verified_role(nil, _), do: {:error, :model_role_not_verified}

  defp verified_role(proof, role) do
    cond do
      proof["role"] != role -> {:error, :model_role_not_verified}
      not fresh?(proof) -> {:error, :model_validation_expired}
      not Enum.all?(~w(tools structured_output), &(&1 in proof["capabilities"])) -> {:error, :model_role_incompatible}
      true -> :ok
    end
  end

  defp fresh?(proof) do
    {:ok, started, _} = DateTime.from_iso8601(proof["validated_at"])
    {:ok, expires, _} = DateTime.from_iso8601(proof["expires_at"])
    now = DateTime.utc_now()
    DateTime.compare(started, now) != :gt and DateTime.compare(expires, now) == :gt
  end

  @spec status(map(), map()) :: map()
  def status(registry, service) do
    result = available(registry, service)
    metadata = get_in(registry, ["catalog", service["id"], "models", service["model"]])
    entry = registry["catalog"][service["id"]] || %{}

    %{
      "state" => state(result, metadata),
      "reason" => if(result != :ok, do: result |> elem(1) |> Atom.to_string()),
      "refreshed_at" => entry["refreshed_at"],
      "discovery_error" => entry["error"],
      "channel_discovery" => if(metadata, do: metadata["discovery"][ModelServices.channel_binding(service)]),
      "validation" => registry["validations"][ModelServices.binding(service)]
    }
  end

  defp state(:ok, _), do: "available"
  defp state({:error, :model_disabled}, _), do: "disabled"
  defp state({:error, reason}, _) when reason in [:model_provider_not_supported, :model_protocol_incompatible, :model_role_incompatible, :model_reasoning_effort_unsupported], do: "incompatible"
  defp state(_, nil), do: "undiscovered"
  defp state(_, _), do: "pending_validation"

  @doc "Paginated AppServer discovery. Errors retain the old catalog and its original timestamp."
  @spec refresh(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh(settings, id, opts \\ []) do
    with {:ok, service} <- ModelServices.snapshot(settings, id, :coder, "catalog"),
         {:ok, models} <- Keyword.get(opts, :discover, &AppServer.list_models/2).(service, opts),
         {:ok, entries} <- discovered_entries(models) do
      registry = settings.model_services
      previous = get_in(registry, ["catalog", id, "models"]) || %{}
      now = DateTime.to_iso8601(DateTime.utc_now())
      channel = ModelServices.channel_binding(service)
      # Preserve administrator disables and known entries omitted by an incomplete channel.
      merged =
        Map.merge(
          previous,
          Map.new(entries, fn {model, entry} ->
            observed = %{"discovered_at" => now, "reasoning_efforts" => entry["reasoning_efforts"], "source" => "appserver"}
            discovery = Map.put(get_in(previous, [model, "discovery"]) || %{}, channel, observed)
            {model, entry |> Map.put("disabled", get_in(previous, [model, "disabled"]) || false) |> Map.put("discovery", discovery)}
          end)
        )

      catalog = %{"models" => merged, "refreshed_at" => DateTime.to_iso8601(DateTime.utc_now()), "error" => nil}
      {:ok, put_in(registry, ["catalog", id], catalog)}
    else
      _ ->
        registry = settings.model_services
        previous = registry["catalog"][id] || %{"models" => %{}, "refreshed_at" => nil}
        {:error, {:model_discovery_failed, put_in(registry, ["catalog", id], Map.put(previous, "error", "discovery_failed"))}}
    end
  end

  defp discovered_entries(models) when is_list(models) do
    Enum.reduce_while(models, {:ok, %{}}, &discovered_entry/2)
  end

  defp discovered_entries(_), do: {:error, :invalid_model_catalog}

  defp discovered_entry(%{"model" => name, "supportedReasoningEfforts" => efforts}, {:ok, acc}) when is_list(efforts) do
    values = Enum.map(efforts, &reasoning_effort/1)

    if ModelServices.identifier?(name) and Enum.all?(values, &is_binary/1) do
      supported = Enum.filter(values, &(&1 in ~w(none minimal low medium high xhigh)))
      {:cont, {:ok, Map.put(acc, name, %{"reasoning_efforts" => supported, "disabled" => false, "discovery" => %{}})}}
    else
      {:halt, {:error, :invalid_model_catalog}}
    end
  end

  defp discovered_entry(_, _), do: {:halt, {:error, :invalid_model_catalog}}
  defp reasoning_effort(entry) when is_map(entry), do: entry["reasoningEffort"]
  defp reasoning_effort(_), do: nil

  @doc "Manual discovery is not inference validation; only administrators can manage this local registry."
  @spec register(map(), String.t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def register(registry, id, model, efforts) do
    entry = registry["catalog"][id] || %{"models" => %{}, "refreshed_at" => nil, "error" => "manual_catalog"}
    preset = registry["presets"][id]

    metadata = %{
      "reasoning_efforts" => efforts,
      "disabled" => get_in(entry, ["models", model, "disabled"]) || false,
      "discovery" => manual_discovery(preset, efforts, get_in(entry, ["models", model, "discovery"]) || %{})
    }

    updated = Map.put(entry, "models", Map.put(entry["models"], model, metadata))
    proposed = put_in(registry, ["catalog", id], updated)

    with true <- Map.has_key?(registry["presets"], id) or {:error, :model_service_not_registered},
         :ok <- ModelServices.validate(proposed) do
      {:ok, proposed}
    end
  end

  defp manual_discovery(nil, _, existing), do: existing

  defp manual_discovery(preset, efforts, existing) do
    observed = %{"discovered_at" => DateTime.to_iso8601(DateTime.utc_now()), "reasoning_efforts" => efforts, "source" => "manual"}
    Map.put(existing, ModelServices.channel_binding(preset), observed)
  end

  @doc "Bind an administrator's externally collected capability proof to precisely this role service."
  @spec attest(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def attest(registry, service, proof) do
    matching = valid_proof?(proof) and proof["role"] == service["role"] and fresh?(proof)

    with :ok <- ModelServices.validate_snapshot(service),
         true <- matching or {:error, :invalid_model_capability_evidence},
         updated = put_in(registry, ["validations", ModelServices.binding(service)], proof),
         :ok <- available(updated, service) do
      {:ok, updated}
    end
  end

  @doc "Real protocol/tool/output probe, with a private random file and explicit model-service binding."
  @spec verify(map(), String.t(), String.t(), atom(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(settings, id, model, role, workspace, opts \\ []) do
    with true <- role in [:coder, :reviewer] or {:error, :invalid_model_role},
         {:ok, template} <- ModelServices.snapshot(settings, id, role, "validation"),
         service = Map.put(template, "model", model),
         :ok <- probe_allowed(settings.model_services, service),
         true <- ExecutionSandbox.enabled?(settings) or {:error, :model_probe_sandbox_required} do
      probe(settings, service, workspace, opts)
    end
  end

  defp probe_allowed(registry, service) do
    case available(registry, service) do
      :ok ->
        :ok

      {:error, reason} when reason in [:model_role_not_verified, :model_validation_expired, :model_role_incompatible] ->
        :ok

      error ->
        error
    end
  end

  defp probe(settings, service, workspace, opts) do
    token = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    file = Path.join(workspace, "model-capability-probe-" <> token)
    schema = %{"type" => "object", "additionalProperties" => false, "required" => ["token"], "properties" => %{"token" => %{"type" => "string"}}}
    {:ok, events} = Agent.start_link(fn -> [] end)
    evidence = Path.join(System.tmp_dir!(), "symphony-model-probe-" <> token)

    context = %{
      workspace: workspace,
      evidence: evidence,
      settings: settings,
      issue: %{id: "model-probe", identifier: "MODEL-PROBE", title: "Role capability validation"},
      opts: Keyword.put(opts, :sandbox_agent_run, Keyword.get(opts, :probe, &ModelServices.run/4))
    }

    try do
      with :ok <- ModelServices.credential_boundary(service, [workspace, evidence]),
           :ok <- File.mkdir_p(Path.join(evidence, "baseline")),
           :ok <- File.write(file, token, [:exclusive]),
           {:ok, result} <-
             ExecutionSandbox.agent(
               context,
               :diagnosis,
               "Use the command execution tool to read #{Path.basename(file)}. Return its contents as the token field in the required JSON object.",
               model: service["model"],
               model_service: service,
               read_only: true,
               tools: false,
               output_schema: schema,
               wall_timeout_ms: 60_000,
               on_message: fn event -> Agent.update(events, &[event | &1]) end
             ),
           {:ok, %{"token" => ^token} = output} <- Jason.decode(result[:output_text] || ""),
           :ok <- probe_success(output, events) do
        now = DateTime.utc_now()

        proof = %{
          "role" => service["role"],
          "validated_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(now, 86_400, :second)),
          "capabilities" => ~w(tools structured_output),
          "actual_model" => result[:actual_model],
          "source" => "inference"
        }

        attest(settings.model_services, service, proof)
      else
        {:error, reason} ->
          {:error, probe_error(reason)}

        _ ->
          {:error, :model_inference_validation_failed}
      end
    after
      File.rm(file)
      File.rm_rf(evidence)
      Agent.stop(events)
    end
  end

  defp probe_error(reason) when reason in [:model_credential_missing, :model_credential_invalid, :model_tool_probe_failed],
    do: reason

  defp probe_error({:model_call_failed, reason}), do: reason
  defp probe_error(reason) when reason in [:turn_timeout, :response_timeout, :wall_timeout], do: reason
  defp probe_error(_), do: :model_inference_validation_failed

  defp probe_success(output, events) do
    if map_size(output) == 1 and Enum.any?(Agent.get(events, & &1), &successful_tool?/1), do: :ok, else: {:error, :model_tool_probe_failed}
  end

  defp successful_tool?(%{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "exitCode" => 0}}}}), do: true
  defp successful_tool?(_), do: false
end
