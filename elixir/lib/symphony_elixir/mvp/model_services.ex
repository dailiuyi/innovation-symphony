defmodule SymphonyElixir.Mvp.ModelServices do
  @moduledoc "Controlled role services, configuration-bound capability evidence and durable defaults."

  import Kernel, except: [binding: 1]

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config, as: RuntimeConfig
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Mvp.Config
  alias SymphonyElixir.Mvp.{ExecutionSandbox, LegacyModelService, ModelCatalog}
  alias SymphonyElixir.{PathSafety, Workflow}

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
      Enum.all?(@roles, &valid_default?(registry, defaults[&1]))
  end

  defp valid_default?(registry, id) when is_binary(id), do: Map.has_key?(registry["presets"], id)

  defp valid_default?(registry, %{"preset" => id, "model" => model, "parameters" => parameters} = selection),
    do:
      map_size(selection) == 3 and Map.has_key?(registry["presets"], id) and
        identifier?(model) and valid_parameters?(parameters) and
        (not Map.has_key?(parameters, "reasoning_effort") or not is_nil(parameters["reasoning_effort"]))

  defp valid_default?(_, _), do: false

  @spec default_id(map(), String.t()) :: String.t()
  def default_id(registry, role) do
    case registry["defaults"][role] do
      %{"preset" => id} -> id
      id -> id
    end
  end

  @spec default_snapshot(map(), atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def default_snapshot(settings, role, source) do
    selection = settings.model_services["defaults"][Atom.to_string(role)]

    id = default_id(settings.model_services, Atom.to_string(role))

    with {:ok, service} <- snapshot(settings, id, role, source) do
      case selection do
        %{"model" => model, "parameters" => parameters} ->
          selected = service |> Map.put("model", model) |> Map.put("parameters", parameters)
          {:ok, attach_evidence(selected, settings.model_services)}

        _ ->
          {:ok, service}
      end
    end
  end

  defp valid_preset?(preset) when is_map(preset) do
    Enum.sort(Map.keys(preset)) == Enum.sort(@preset_keys) and
      is_integer(preset["version"]) and preset["version"] > 0 and
      identifier?(preset["provider"]) and identifier?(preset["adapter"]) and identifier?(preset["model"]) and
      preset_parameters?(preset) and valid_connection?(preset["connection"]) and
      valid_credential?(preset["credential_ref"])
  end

  defp valid_preset?(_), do: false

  defp preset_parameters?(preset), do: valid_parameters?(preset["parameters"]) and provider_parameters?(preset)

  defp provider_parameters?(%{"provider" => "deepseek", "adapter" => "deepseek_responses", "parameters" => parameters}),
    do: parameters["reasoning_effort"] in [nil, "none", "low", "high", "max"]

  defp provider_parameters?(_), do: true

  defp valid_parameters?(parameters) when is_map(parameters) do
    # Existing presets and frozen snapshots used null to mean unspecified.
    # Keep their exact representation so capability bindings remain unchanged.
    Enum.all?(parameters, fn
      {"reasoning_effort", value} -> is_nil(value) or value in ~w(none minimal low medium high xhigh max)
      _ -> false
    end)
  end

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

  @doc """
  Prepares a dedicated codex home directory for an unsandboxed run so that session artifacts
  remain available for operator inspection and dashboard auditing.

  Does NOT support resuming across attempts or controller restarts (a fresh directory is allocated).
  When sandbox execution is enabled, returns {:ok, nil} to avoid leaving unused directories.
  """
  @spec standalone_run_home(map()) :: {:ok, Path.t() | nil} | {:error, term()}
  def standalone_run_home(settings) when is_map(settings) do
    if ExecutionSandbox.enabled?(settings) do
      {:ok, nil}
    else
      case Map.get(settings, :state_dir) do
        state_dir when is_binary(state_dir) ->
          if File.dir?(state_dir) do
            root = Path.dirname(state_dir)
            sandboxes = Path.join(root, "sandboxes")
            run = Path.join(sandboxes, "run-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}")
            home = Path.join(run, "codex-home")

            with :ok <- File.mkdir_p(home),
                 :ok <- File.chmod(home, 0o700) do
              prune_runs(sandboxes, 50)
              {:ok, home}
            else
              {:error, reason} -> {:error, {:standalone_run_home_failed, reason}}
            end
          else
            {:ok, nil}
          end

        _ ->
          {:ok, nil}
      end
    end
  end

  def standalone_run_home(_), do: {:ok, nil}

  @doc """
  Prunes historical sandbox runs in reverse modification order, retaining at most keep_count directories.

  Uses the most-recent mtime across the entire subtree of each run directory so that
  long-running tasks whose session files are written into subdirectories are never evicted
  based on a stale top-level mtime. Only directories whose entire subtree has gone quiet
  (i.e. the keep_count oldest by subtree-mtime) are removed.
  """
  @spec prune_runs(Path.t(), non_neg_integer()) :: :ok
  def prune_runs(sandboxes_dir, keep_count \\ 50) do
    if File.dir?(sandboxes_dir) do
      case File.ls(sandboxes_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.starts_with?(&1, "run-"))
          |> Enum.map(&Path.join(sandboxes_dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.map(fn dir -> {dir, subtree_mtime(dir)} end)
          |> Enum.sort_by(fn {_dir, mtime} -> mtime end, :desc)
          |> Enum.drop(keep_count)
          |> Enum.each(fn {dir, _mtime} -> File.rm_rf(dir) end)

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # Returns the most-recent posix mtime found anywhere in the directory tree rooted at `dir`.
  # Falls back to the top-level directory mtime when no descendant files are accessible.
  # Depth is capped at 6 levels to bound the scan time for large session trees.
  @spec subtree_mtime(Path.t()) :: integer()
  defp subtree_mtime(dir), do: subtree_mtime(dir, 0, top_mtime(dir))

  defp subtree_mtime(_dir, depth, acc) when depth >= 6, do: acc

  defp subtree_mtime(dir, depth, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn name, best ->
          path = Path.join(dir, name)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime} = stat} ->
              updated = max(best, mtime)

              if stat.type == :directory do
                subtree_mtime(path, depth + 1, updated)
              else
                updated
              end

            _ ->
              best
          end
        end)

      _ ->
        acc
    end
  end

  defp top_mtime(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  @spec load(Path.t(), map() | nil) :: {:ok, map() | nil} | {:error, term()}
  def load(path, fallback) do
    case File.read(path) do
      {:ok, raw} ->
        with {:ok, registry} <- Jason.decode(raw), :ok <- validate(registry) do
          {:ok, registry}
        else
          {:error, %Jason.DecodeError{}} -> {:error, :invalid_model_services_json}
          error -> error
        end

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
      id = default_id(proposed, role)

      changed =
        is_nil(current) or current["defaults"][role] != proposed["defaults"][role] or
          current["presets"][id] != proposed["presets"][id]

      check_default(changed, settings, role, id)
    end)
  end

  defp check_default(false, _, _, _), do: {:cont, :ok}

  defp check_default(true, settings, role, _id) do
    with {:ok, service} <- default_snapshot(settings, String.to_existing_atom(role), "project_default"),
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

    result =
      case selection do
        "default" -> default_snapshot(settings, role, source)
        id -> snapshot(settings, id, role, source)
      end

    with {:ok, service} <- result,
         :ok <- ModelCatalog.available(registry, service) do
      services = Map.put(Map.get(selected, :services, %{}), Atom.to_string(role), service)
      {:ok, selected |> Map.put(role, service["model"]) |> Map.put(:services, services)}
    end
  end

  @spec select_model(map(), atom(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def select_model(settings, role, model, source, selected) do
    with {:ok, service} <- default_snapshot(settings, role, source),
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
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")) do
      {:ok, fingerprint(stable_auth_identity(raw))}
    end
  end

  # OAuth tokens rotate during normal login refresh. Bind the local auth file
  # to its account and subject; unfamiliar formats retain the legacy binding.
  defp stable_auth_identity(raw) do
    with {:ok, %{"auth_mode" => "chatgpt", "tokens" => tokens}} <- Jason.decode(raw),
         %{"account_id" => account, "id_token" => jwt} <- tokens,
         true <- is_binary(account) and account != "" and is_binary(jwt),
         [_, payload, _] <- String.split(jwt, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"iss" => "https://auth.openai.com", "sub" => subject} = claims} <- Jason.decode(decoded),
         true <- is_binary(subject) and subject != "",
         %{"chatgpt_account_id" => ^account} <- claims["https://api.openai.com/auth"] do
      :erlang.term_to_binary({:chatgpt_account_v1, account, subject}, [:deterministic])
    else
      _ -> raw
    end
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
    service["role"] in @roles and snapshot_command_safe?(service) and
      is_binary(service["source"])
  end

  defp snapshot_command_safe?(%{"source" => "legacy_migration"} = service) do
    case legacy_command_config(service["command"]) do
      {:ok, overrides} ->
        not Map.has_key?(overrides, {"", "model_reasoning_effort"}) or
          overrides[{"", "model_reasoning_effort"}] == service["parameters"]["reasoning_effort"]

      _ ->
        false
    end
  end

  defp snapshot_command_safe?(service), do: command_safe?(service["command"])

  defp legacy_command_config(command) do
    with {:ok, clean, overrides} <- LegacyModelService.command_config(command),
         true <- command_safe?(clean) or {:error, :model_service_command_unsafe} do
      {:ok, overrides}
    end
  end

  defp command_safe?(command) when is_binary(command) do
    normalized = String.replace(command, ~r/['"\\]/, "")

    command != "" and not String.contains?(command, [<<0>>, "\n", "\r", "$", "`"]) and
      not Regex.match?(~r/(?i)(?:[a-z0-9_]*(?:api_key|token|secret|password)\s*=|--(?:api-key|token|password)\b)/, normalized) and
      not Regex.match?(~r/(?i)(?:CODEX_HOME|SYMPHONY_MODEL_KEY|model_provider|base_url|env_key|(?:^|\s)(?:--(?:config|profile|model)(?:\b|=)|-[cpm]))/, normalized)
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
           {:ok, current} <- current_authorization(context.settings),
           :ok <- current_permission(current.model_services, service, current),
           :ok <- credential_ready(service) do
        {:ok, [model: service["model"], model_service: service]}
      end
    end
  end

  defp current_authorization(settings) do
    # Read the task's original workflow directly: the store deliberately keeps
    # last-known-good settings on reload failure, which is unsafe for revocation.
    with workflow_path when is_binary(workflow_path) <- Map.get(settings, :workflow_path),
         {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, runtime} <- Schema.parse(workflow.config),
         :ok <- RuntimeConfig.validate_settings(runtime),
         {:ok, %{enabled: true} = current} <- Config.settings(workflow, Path.dirname(workflow_path)),
         # Keep the original persistent authority location even if state_dir changes.
         {:ok, registry} <- load(path(settings), get_in(workflow.config, ["mvp", "model_services"])) do
      {:ok, Map.put(current, :model_services, registry)}
    else
      _ -> {:error, :model_service_authorization_unavailable}
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

    restrictions =
      ~s([features]\napps = false\nplugins = false\nhooks = false\ncodex_hooks = false\ncode_mode = false\njs_repl = false\nbrowser_use = false\ncomputer_use = false\nskip_host_skill_discovery = true\nmulti_agent = false\nshell_snapshot = false\n)

    provider = "web_search = \"disabled\"\n" <> effort_config(service) <> summary_config(service) <> provider_config(service, credential)

    with :ok <- connection_ready(service), :ok <- File.write(Path.join(home, "config.toml"), provider <> restrictions, [:exclusive]), do: link_auth(home, credential)
  end

  # Built-in provider IDs are reserved in Codex. Keep its auth.json handling and
  # freeze the route using supported root fields, never model_providers.openai.
  defp provider_config(service, {:home, home}) do
    url = service["connection"]["base_url"]
    route_key = if chatgpt_auth?(home), do: "chatgpt_base_url", else: "openai_base_url"
    route = if route_key == "chatgpt_base_url", do: String.replace_suffix(url, "/codex", ""), else: url
    ~s(model_provider = "openai"\n#{route_key} = #{Jason.encode!(route)}\n)
  end

  defp provider_config(service, {:env, _, _}) do
    ~s(model_provider = "symphony"\n[model_providers.symphony]\nname = #{Jason.encode!(service["provider"])}\nbase_url = #{Jason.encode!(service["connection"]["base_url"])}\nwire_api = "responses"\nenv_key = "SYMPHONY_MODEL_KEY"\n)
  end

  @spec connection_ready(map()) :: :ok | {:error, atom()}
  def connection_ready(%{"provider" => "deepseek", "credential_ref" => "auth_home:" <> _}), do: {:error, :model_auth_route_incompatible}

  def connection_ready(%{"credential_ref" => "auth_home:" <> home, "connection" => connection}) do
    chatgpt_route = valid_connection?(connection) and String.ends_with?(connection["base_url"], "/codex")

    if chatgpt_auth?(home) and not chatgpt_route,
      do: {:error, :model_auth_route_incompatible},
      else: :ok
  end

  def connection_ready(_), do: :ok

  defp effort_config(service) do
    case service["parameters"]["reasoning_effort"] do
      nil -> ""
      effort -> "model_reasoning_effort = #{Jason.encode!(effort)}\n"
    end
  end

  # Responses clients otherwise add reasoning.summary even when effort is absent.
  # Fixed channels support no reasoning controls; DeepSeek maps effort only.
  # Preserve the existing unspecified OpenAI preset/null behavior.
  defp summary_config(%{"source" => source}) when source in ["catalog", "legacy_migration"], do: ""
  defp summary_config(%{"provider" => "deepseek"}), do: "model_reasoning_summary = \"none\"\n"
  defp summary_config(%{"parameters" => parameters}) when map_size(parameters) == 0, do: "model_reasoning_summary = \"none\"\n"
  defp summary_config(_), do: ""

  defp link_auth(home, {:home, original}), do: File.ln_s(Path.join(original, "auth.json"), Path.join(home, "auth.json"))
  defp link_auth(_, {:env, _, _}), do: :ok

  # Codex's ChatGPT OAuth route differs from the API-key Responses endpoint.
  # Normalize only the legacy API default; explicit administrator channels remain explicit.
  defp effective_connection(%{"credential_ref" => "auth_home:" <> home, "connection" => %{"base_url" => "https://api.openai.com/v1"}} = service) do
    if chatgpt_auth?(home), do: put_in(service, ["connection", "base_url"], "https://chatgpt.com/backend-api/codex"), else: service
  end

  defp effective_connection(service), do: service

  @doc false
  @spec chatgpt_auth?(Path.t()) :: boolean()
  def chatgpt_auth?(home) do
    with {:ok, raw} <- File.read(Path.join(home, "auth.json")),
         {:ok, %{"tokens" => tokens}} when is_map(tokens) <- Jason.decode(raw) do
      true
    else
      _ -> false
    end
  end

  @doc "Freeze newly claimed legacy workflows without asserting historical capability evidence."
  @spec freeze(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(models, settings, opts \\ [])
  @spec freeze(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(%{services: services}, _settings, _opts) do
    with true <- is_map(services) or {:error, :invalid_model_service_snapshot},
         :ok <- validate_snapshot(services["coder"]),
         :ok <- validate_snapshot(services["reviewer"]) do
      {:ok, services}
    end
  end

  def freeze(models, settings, opts) do
    command = Map.get(settings, :model_command, SymphonyElixir.Config.settings!().codex.command)
    home = get_in(settings, [:sandbox, "auth_home"]) || System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")

    with {:ok, overrides} <- legacy_command_config(command),
         {:ok, preset} <- LegacyModelService.read(home, Map.get(settings, :sandbox, %{}), Keyword.get(opts, :environment, &System.get_env/1), overrides) do
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
