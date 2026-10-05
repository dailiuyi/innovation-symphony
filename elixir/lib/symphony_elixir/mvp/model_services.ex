defmodule SymphonyElixir.Mvp.ModelServices do
  @moduledoc "Controlled role services, configuration-bound capability evidence and durable defaults."

  import Kernel, except: [binding: 1]

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Mvp.{LegacyModelService, ModelCatalog}
  alias SymphonyElixir.PathSafety

  @roles ~w(coder reviewer)
  @preset_keys ~w(version provider adapter model parameters connection credential_ref)
  @snapshot_keys ~w(id version provider adapter model parameters connection credential_ref credential_identity command source role capability_evidence)

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(registry) do
    if is_map(registry) and Map.keys(registry) -- ~w(revision defaults presets catalog validations disabled_models) == [] and
         is_integer(registry["revision"]) and registry["revision"] >= 0 and
         valid_presets?(registry["presets"]) and valid_defaults?(registry) and valid_disables?(registry) and
         ModelCatalog.valid?(registry["catalog"], registry["validations"]) do
      :ok
    else
      {:error, :invalid_model_services}
    end
  end

  defp valid_disables?(registry) do
    models = Map.get(registry, "disabled_models", [])
    is_list(models) and Enum.all?(models, &identifier?/1)
  end

  defp valid_presets?(presets) when is_map(presets) and map_size(presets) > 0,
    do: Enum.all?(presets, fn {id, preset} -> identifier?(id) and valid_preset?(preset) end)

  defp valid_presets?(_), do: false

  defp valid_defaults?(registry) do
    defaults = registry["defaults"]

    is_map(defaults) and Enum.sort(Map.keys(defaults)) == Enum.sort(@roles) and
      Enum.all?(@roles, &Map.has_key?(registry["presets"], defaults[&1]))
  end

  defp valid_preset?(preset) when is_map(preset) do
    Enum.sort(Map.keys(preset)) == Enum.sort(@preset_keys) and
      is_integer(preset["version"]) and preset["version"] > 0 and
      identifier?(preset["provider"]) and identifier?(preset["adapter"]) and identifier?(preset["model"]) and
      valid_parameters?(preset["parameters"]) and valid_connection?(preset["connection"]) and
      valid_credential?(preset["credential_ref"])
  end

  defp valid_preset?(_), do: false

  defp valid_parameters?(parameters) when is_map(parameters),
    do:
      Map.keys(parameters) -- ["reasoning_effort"] == [] and
        Map.get(parameters, "reasoning_effort") in [nil, "none", "minimal", "low", "medium", "high", "xhigh"]

  defp valid_parameters?(_), do: false

  defp valid_connection?(%{"base_url" => url, "protocol" => protocol} = connection) when is_binary(url) do
    uri = URI.parse(url)

    map_size(connection) == 2 and protocol == "responses" and uri.scheme == "https" and
      is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_connection?(_), do: false

  defp valid_credential?("env:" <> name), do: Regex.match?(~r/\A[A-Z][A-Z0-9_]*\z/, name)
  defp valid_credential?("auth_home:" <> path), do: Path.type(path) == :absolute and Path.expand(path) == path and not String.contains?(path, ["\n", "\r", <<0>>])
  defp valid_credential?(_), do: false

  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z/, value)

  @spec path(map()) :: Path.t()
  def path(settings), do: Path.join(settings.state_dir, "model-services.json")

  @spec load(Path.t(), map() | nil) :: {:ok, map() | nil} | {:error, term()}
  def load(path, fallback) do
    case File.read(path) do
      {:ok, raw} ->
        with {:ok, registry} <- Jason.decode(raw), :ok <- validate(registry), do: {:ok, registry}

      {:error, :enoent} ->
        fallback_registry(fallback)

      {:error, reason} ->
        {:error, {:model_services_read, reason}}
    end
  end

  defp fallback_registry(nil), do: {:ok, nil}
  defp fallback_registry(fallback), do: with(:ok <- validate(fallback), do: {:ok, fallback})

  @doc "Compare-and-swap under an exclusive local file lock; failed writes leave the previous file intact."
  @spec save(Path.t(), map() | nil, non_neg_integer(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def save(path, fallback, expected_revision, proposed, command \\ "codex app-server") do
    with :ok <- validate(proposed), :ok <- File.mkdir_p(Path.dirname(path)), {:ok, lock} <- File.open(path <> ".lock", [:write, :exclusive]) do
      try do
        save_locked(path, fallback, expected_revision, proposed, command)
      after
        File.close(lock)
        File.rm(path <> ".lock")
      end
    else
      {:error, :eexist} -> {:error, :model_services_busy}
      error -> error
    end
  end

  defp save_locked(path, fallback, expected, proposed, command) do
    temporary = path <> ".next"

    try do
      with {:ok, current} <- load(path, fallback),
           true <- (current || %{"revision" => 0})["revision"] == expected or {:error, :model_services_conflict},
           :ok <- version_changes(current, proposed),
           :ok <- changed_defaults(current, proposed, command),
           updated = Map.put(proposed, "revision", expected + 1),
           :ok <- File.write(temporary, Jason.encode!(updated, pretty: true), [:exclusive, :sync]),
           :ok <- File.rename(temporary, path) do
        {:ok, updated}
      end
    after
      File.rm(temporary)
    end
  end

  defp version_changes(nil, _), do: :ok

  defp version_changes(current, proposed) do
    valid =
      Enum.all?(proposed["presets"], fn {id, preset} ->
        old = current["presets"][id]
        is_nil(old) or old == preset or preset["version"] > old["version"]
      end)

    if valid, do: :ok, else: {:error, :model_service_version_required}
  end

  defp changed_defaults(current, proposed, command) do
    settings = %{model_services: proposed, model_command: command}

    Enum.reduce_while(@roles, :ok, fn role, :ok ->
      id = proposed["defaults"][role]

      changed =
        is_nil(current) or current["defaults"][role] != id or
          current["presets"][id] != proposed["presets"][id]

      check_default(changed, settings, role, id)
    end)
  end

  defp check_default(false, _, _, _), do: {:cont, :ok}

  defp check_default(true, settings, role, id) do
    with {:ok, service} <- snapshot(settings, id, String.to_existing_atom(role), "project_default"),
         :ok <- ModelCatalog.available(settings.model_services, service) do
      {:cont, :ok}
    else
      error -> {:halt, error}
    end
  end

  @spec read(map()) :: {:ok, map()} | {:error, term()}
  def read(settings) do
    with {:ok, registry} <- load(path(settings), Map.get(settings, :model_services)),
         true <- is_map(registry) or {:error, :model_services_not_configured} do
      presets =
        Map.new(registry["presets"], fn {id, preset} ->
          {id, Map.put(preset, "credential_configured", credential(preset["credential_ref"]) != {:error, :model_credential_missing})}
        end)

      statuses = availability(%{settings | model_services: registry}, registry)
      {:ok, registry |> Map.put("presets", presets) |> Map.put("availability", statuses)}
    end
  end

  defp availability(settings, registry) do
    Map.new(registry["presets"], fn {id, _} ->
      models = get_in(registry, ["catalog", id, "models"]) || %{}
      {id, Map.new(models, fn {model, _} -> {model, role_statuses(settings, registry, id, model)} end)}
    end)
  end

  defp role_statuses(settings, registry, id, model) do
    Map.new([:coder, :reviewer], fn role ->
      status =
        case snapshot(settings, id, role, "catalog") do
          {:ok, service} -> ModelCatalog.status(registry, Map.put(service, "model", model))
          {:error, reason} -> %{"state" => "incompatible", "reason" => Atom.to_string(reason)}
        end

      {Atom.to_string(role), status}
    end)
  end

  @spec select(map(), atom(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def select(settings, role, selection, source, selected) do
    registry = settings.model_services
    role_name = Atom.to_string(role)
    id = if selection == "default", do: registry["defaults"][role_name], else: selection

    with {:ok, service} <- snapshot(settings, id, role, source),
         :ok <- ModelCatalog.available(registry, service) do
      services = Map.put(Map.get(selected, :services, %{}), role_name, service)
      {:ok, selected |> Map.put(role, service["model"]) |> Map.put(:services, services)}
    end
  end

  @spec select_model(map(), atom(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def select_model(settings, role, model, source, selected) do
    id = settings.model_services["defaults"][Atom.to_string(role)]

    with {:ok, service} <- snapshot(settings, id, role, source),
         service = service |> Map.put("model", model) |> attach_evidence(settings.model_services),
         :ok <- ModelCatalog.available(settings.model_services, service) do
      {:ok, selected |> Map.put(role, model) |> Map.put(:services, Map.put(Map.get(selected, :services, %{}), Atom.to_string(role), service))}
    end
  end

  @spec snapshot(map(), String.t(), atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(settings, id, role, source) do
    case settings.model_services["presets"][id] do
      nil ->
        {:error, :model_service_not_registered}

      preset ->
        build_snapshot(settings, preset, id, role, source)
    end
  end

  defp build_snapshot(settings, preset, id, role, source) do
    with true <- command_safe?(settings.model_command) or {:error, :model_service_command_unsafe} do
      service =
        Map.merge(effective_connection(preset), %{
          "id" => id,
          "role" => Atom.to_string(role),
          "command" => settings.model_command,
          "source" => source,
          "credential_identity" => safe_identity(preset["credential_ref"]),
          "capability_evidence" => nil
        })

      {:ok, attach_evidence(service, settings.model_services)}
    end
  end

  defp attach_evidence(service, registry),
    do: Map.put(service, "capability_evidence", registry["validations"][binding(service)])

  defp safe_identity(reference) do
    case credential_identity(reference) do
      {:ok, identity} -> identity
      _ -> nil
    end
  end

  @spec credential_identity(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def credential_identity(reference) do
    with {:ok, value} <- credential(reference), do: identity(value)
  end

  defp identity({:env, _, secret}), do: {:ok, fingerprint(secret)}

  defp identity({:home, home}) do
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")), do: {:ok, fingerprint(raw)}
  end

  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @spec identity_matches(map()) :: :ok | {:error, atom()}
  def identity_matches(service) do
    with {:ok, current} <- credential_identity(service["credential_ref"]) do
      legacy_unknown = service["source"] == "legacy_migration" and is_nil(service["credential_identity"])
      if current == service["credential_identity"] or legacy_unknown, do: :ok, else: {:error, :model_credential_changed}
    end
  end

  @spec channel_binding(map()) :: String.t()
  def channel_binding(service) do
    identity = if Map.has_key?(service, "credential_identity"), do: service["credential_identity"], else: safe_identity(service["credential_ref"])

    service
    |> effective_connection()
    |> Map.put("credential_identity", identity)
    |> Map.take(~w(provider adapter connection credential_ref credential_identity))
    |> :erlang.term_to_binary([:deterministic])
    |> fingerprint()
  end

  @spec binding(map()) :: String.t()
  def binding(service) do
    # Fixed key order, independent of map enumeration or JSON encoder order.
    (@snapshot_keys -- ["source", "capability_evidence"])
    |> Enum.map(&{&1, service[&1]})
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec validate_snapshot(term()) :: :ok | {:error, atom()}
  def validate_snapshot(service) do
    if is_map(service) and Enum.sort(Map.keys(service)) == Enum.sort(@snapshot_keys) and
         valid_preset?(Map.take(service, @preset_keys)) and identifier?(service["id"]) and
         valid_snapshot_origin?(service) and valid_snapshot_identity?(service["credential_identity"]) and
         valid_snapshot_evidence?(service) do
      :ok
    else
      {:error, :invalid_model_service_snapshot}
    end
  end

  defp valid_snapshot_origin?(service) do
    service["role"] in @roles and command_safe?(service["command"]) and
      is_binary(service["source"])
  end

  defp command_safe?(command) when is_binary(command) do
    normalized = String.replace(command, ~r/['"\\]/, "")

    command != "" and not String.contains?(command, [<<0>>, "\n", "\r", "$", "`"]) and
      not Regex.match?(~r/(?i)(?:[a-z0-9_]*(?:api_key|token|secret|password)\s*=|--(?:api-key|token|password)\b)/, normalized) and
      not Regex.match?(~r/(?i)(?:CODEX_HOME|model_provider|base_url|env_key|(?:^|\s)(?:--(?:config|profile|model)(?:\b|=)|-[cpm]))/, normalized)
  end

  defp command_safe?(_), do: false

  defp valid_snapshot_identity?(nil), do: true
  defp valid_snapshot_identity?(identity), do: is_binary(identity) and Regex.match?(~r/\A[0-9a-f]{64}\z/, identity)
  defp valid_snapshot_evidence?(%{"capability_evidence" => nil}), do: true

  defp valid_snapshot_evidence?(service),
    do: ModelCatalog.valid?(%{}, %{binding(service) => service["capability_evidence"]})

  @spec options(map(), atom()) :: {:ok, keyword()} | {:error, term()}
  def options(context, role) do
    key = if role == :reviewer, do: "reviewer", else: "coder"
    services = Map.get(context, :services)

    if is_nil(services) do
      # Legacy contexts lack connection/evidence history. The managed AppServer
      # rejects these; injected test adapters retain the existing test contract.
      {:ok, [model: Map.fetch!(context.models, String.to_existing_atom(key))]}
    else
      service = services[key]

      with :ok <- validate_snapshot(service),
           :ok <- credential_boundary(service, [Map.get(context, :workspace), Map.get(context, :evidence)]),
           {:ok, registry} <- load(path(context.settings), Map.get(context.settings, :model_services)),
           :ok <- current_permission(registry, service, context.settings),
           :ok <- credential_ready(service) do
        {:ok, [model: service["model"], model_service: service]}
      end
    end
  end

  defp credential_ready(%{"source" => "legacy_migration"}), do: :ok

  defp credential_ready(service) do
    identity_matches(service)
  end

  defp current_permission(registry, %{"source" => "legacy_migration"} = service, settings) do
    disabled = if registry, do: Map.get(registry, "disabled_models", []), else: []
    allowed = Map.get(settings, :allowed_models, [])

    cond do
      service["model"] in disabled -> {:error, :model_disabled}
      service["model"] not in allowed -> {:error, :model_service_revoked}
      true -> :ok
    end
  end

  defp current_permission(nil, _, _), do: {:error, :model_services_not_configured}
  defp current_permission(registry, service, _), do: ModelCatalog.available(registry, service)

  @spec credential_boundary(map() | nil, [Path.t() | nil]) :: :ok | {:error, atom()}
  def credential_boundary(%{"credential_ref" => "auth_home:" <> home}, roots) do
    # stat follows links with the kernel's bounded resolver, so a loop cannot
    # hang the application-level canonicalizer.
    path = Path.join(home, "auth.json")
    stat = File.stat(path)

    canonical =
      if match?({:ok, %{type: :regular}}, stat) or stat == {:error, :enoent},
        do: PathSafety.canonicalize(path),
        else: {:error, :model_credential_untrusted}

    case canonical do
      {:ok, auth} ->
        forbidden = Enum.reject(roots, &is_nil/1)
        if Enum.any?(forbidden, &(auth == Path.expand(&1) or String.starts_with?(auth, Path.expand(&1) <> "/"))), do: {:error, :model_credential_untrusted}, else: :ok

      _ ->
        {:error, :model_credential_untrusted}
    end
  end

  def credential_boundary(_, _), do: :ok

  @spec credential(String.t()) :: {:ok, {:env, String.t(), String.t()} | {:home, Path.t()}} | {:error, atom()}
  def credential("env:" <> name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, {:env, name, value}}
      _ -> {:error, :model_credential_missing}
    end
  end

  def credential("auth_home:" <> home) do
    case File.read(Path.join(home, "auth.json")) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, auth} when is_map(auth) and map_size(auth) > 0 -> {:ok, {:home, home}}
          _ -> {:error, :model_credential_invalid}
        end

      _ ->
        {:error, :model_credential_missing}
    end
  end

  def credential(_), do: {:error, :model_credential_missing}

  @spec write_home(Path.t(), map(), tuple()) :: :ok | {:error, term()}
  def write_home(home, service, credential) do
    service = effective_connection(service)
    provider_id = if match?({:home, _}, credential), do: "openai", else: "symphony"

    provider =
      "model_provider = #{Jason.encode!(provider_id)}\n" <>
        "web_search = \"disabled\"\n" <>
        effort_config(service) <>
        ~s([model_providers.#{provider_id}]\nname = "OpenAI"\nbase_url = #{Jason.encode!(service["connection"]["base_url"])}\nwire_api = "responses"\n) <>
        if(match?({:env, _, _}, credential), do: "env_key = \"SYMPHONY_MODEL_KEY\"\n", else: "requires_openai_auth = true\n")

    restrictions =
      ~s([features]\napps = false\nplugins = false\nhooks = false\ncodex_hooks = false\ncode_mode = false\njs_repl = false\nbrowser_use = false\ncomputer_use = false\nskip_host_skill_discovery = true\nmulti_agent = false\nshell_snapshot = false\n)

    with :ok <- connection_ready(service), :ok <- File.write(Path.join(home, "config.toml"), provider <> restrictions, [:exclusive]), do: link_auth(home, credential)
  end

  @spec connection_ready(map()) :: :ok | {:error, atom()}
  def connection_ready(%{"credential_ref" => "auth_home:" <> home} = service) do
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")),
         {:ok, %{"tokens" => tokens}} when is_map(tokens) <- Jason.decode(raw) do
      if service["connection"]["base_url"] == "https://chatgpt.com/backend-api/codex", do: :ok, else: {:error, :model_auth_route_incompatible}
    else
      _ -> :ok
    end
  end

  def connection_ready(_), do: :ok

  defp effort_config(service) do
    case service["parameters"]["reasoning_effort"] do
      nil -> ""
      effort -> "model_reasoning_effort = #{Jason.encode!(effort)}\n"
    end
  end

  defp link_auth(home, {:home, original}), do: File.ln_s(Path.join(original, "auth.json"), Path.join(home, "auth.json"))
  defp link_auth(_, {:env, _, _}), do: :ok

  # Codex's ChatGPT OAuth route differs from the API-key Responses endpoint.
  # Normalize only the legacy API default; explicit administrator channels remain explicit.
  defp effective_connection(%{"credential_ref" => "auth_home:" <> home, "connection" => %{"base_url" => "https://api.openai.com/v1"}} = service) do
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")),
         {:ok, %{"tokens" => tokens}} when is_map(tokens) <- Jason.decode(raw) do
      put_in(service, ["connection", "base_url"], "https://chatgpt.com/backend-api/codex")
    else
      _ -> service
    end
  end

  defp effective_connection(service), do: service

  @doc "Freeze newly claimed legacy workflows without asserting historical capability evidence."
  @spec freeze(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(models, settings, opts \\ [])
  @spec freeze(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(%{services: services}, _settings, _opts), do: {:ok, services}

  def freeze(models, settings, opts) do
    command = Map.get(settings, :model_command, SymphonyElixir.Config.settings!().codex.command)
    home = get_in(settings, [:sandbox, "auth_home"]) || System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")

    with true <- command_safe?(command) or {:error, :model_service_command_unsafe},
         {:ok, preset} <- LegacyModelService.read(home, Map.get(settings, :sandbox, %{}), Keyword.get(opts, :environment, &System.get_env/1)) do
      services =
        Map.new([:coder, :reviewer], fn role ->
          service =
            Map.merge(preset, %{
              "id" => "legacy-#{role}",
              "model" => models[role],
              "credential_identity" => safe_identity(preset["credential_ref"]),
              "capability_evidence" => nil,
              "command" => command,
              "source" => "legacy_migration",
              "role" => Atom.to_string(role)
            })

          {Atom.to_string(role), effective_connection(service)}
        end)

      {:ok, services}
    end
  end

  @spec failure_reason(term()) :: term()
  def failure_reason({kind, error} = original) when kind in [:response_error, :turn_failed] do
    details = if is_map(error), do: Map.get(error, "error", error), else: error
    category = error_category(details)
    if category, do: {:model_call_failed, category}, else: original
  end

  def failure_reason(reason), do: reason

  defp error_category(error) when is_map(error) do
    info = error["codexErrorInfo"]
    code = codex_error_code(info) || error["code"] || error["status"]

    case code do
      value when value in [401, 403, "unauthorized", "permission_denied", "invalid_api_key"] -> :model_account_forbidden
      value when value in [429, "rate_limit_exceeded"] -> :model_rate_limited
      "insufficient_quota" -> :model_quota_exhausted
      "model_not_found" -> :model_not_found
      value when value in [500, 502, 503, 504, "server_error"] -> :model_service_unavailable
      _ -> nil
    end
  end

  defp error_category(_), do: nil

  defp codex_error_code(info) when is_map(info) do
    info
    |> Map.values()
    |> Enum.find_value(fn
      %{"httpStatusCode" => status} -> status
      _ -> nil
    end)
  end

  defp codex_error_code("usageLimitExceeded"), do: "insufficient_quota"
  defp codex_error_code("rateLimitExceeded"), do: "rate_limit_exceeded"
  defp codex_error_code(info) when info in ["serverOverloaded", "internalServerError"], do: "server_error"
  defp codex_error_code("unauthorized"), do: "unauthorized"
  defp codex_error_code(_), do: nil

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, options) do
    if Keyword.has_key?(options, :model_service),
      do: AppServer.run(workspace, prompt, issue, options),
      else: {:error, :legacy_model_service_snapshot_missing}
  end
end
