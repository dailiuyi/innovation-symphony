defmodule SymphonyElixir.Mvp.LegacyModelService do
  @moduledoc "Conservative migration of effective legacy Codex routing; ambiguous settings stop admission."

  alias SymphonyElixir.Mvp.ModelServices

  @root_keys ~w(model model_provider model_reasoning_effort openai_base_url chatgpt_base_url approval_policy sandbox_mode web_search personality)
  @provider_keys ~w(name base_url wire_api env_key requires_openai_auth)

  @spec read(Path.t(), map(), (String.t() -> String.t() | nil)) :: {:ok, map()} | {:error, atom()}
  @spec read(Path.t(), map(), (String.t() -> String.t() | nil), map()) :: {:ok, map()} | {:error, atom()}
  def read(home, sandbox, environment, overrides \\ %{}) do
    with {:ok, config} <- effective_config(home, sandbox),
         config = Map.merge(config, overrides),
         true <- native_fields?(config),
         {:ok, provider} <- provider(config),
         {:ok, reference} <- reference(provider, home, environment),
         parameters = parameters(config, sandbox),
         connection = connection(config, provider, reference, environment),
         preset = %{
           "version" => 1,
           "provider" => "openai",
           "adapter" => "codex_app_server",
           "model" => "gpt-legacy",
           "parameters" => parameters,
           "connection" => connection,
           "credential_ref" => reference
         },
         registry = %{"revision" => 0, "defaults" => %{"coder" => "legacy", "reviewer" => "legacy"}, "presets" => %{"legacy" => preset}, "catalog" => %{}, "validations" => %{}},
         :ok <- ModelServices.validate(registry) do
      {:ok, preset}
    else
      _ -> {:error, :legacy_model_service_migration_required}
    end
  end

  @doc "Extract only representable legacy effort flags, leaving all other flags for the routing safety check."
  @spec command_config(term()) :: {:ok, String.t(), map()} | {:error, atom()}
  def command_config(command) when is_binary(command) do
    # This command is later executed by a shell. Do not parse across another
    # invocation, expansion or redirection and accidentally bless its flags.
    if String.contains?(command, [<<0>>, "\n", "\r", "$", "`", "#", ";", "&", "|", "<", ">", "(", ")"]) do
      {:error, :model_service_command_unsafe}
    else
      command |> OptionParser.split() |> command_config([], %{})
    end
  rescue
    _error in [ArgumentError, RuntimeError] -> {:error, :model_service_command_unsafe}
  end

  def command_config(_), do: {:error, :model_service_command_unsafe}

  defp command_config([], clean, overrides), do: {:ok, clean |> Enum.reverse() |> Enum.join(" "), overrides}

  defp command_config([flag, value | rest], clean, overrides) when flag in ["--config", "-c"],
    do: command_override(value, rest, clean, overrides)

  defp command_config(["--config=" <> value | rest], clean, overrides), do: command_override(value, rest, clean, overrides)
  defp command_config(["-c=" <> value | rest], clean, overrides), do: command_override(value, rest, clean, overrides)
  defp command_config(["-c" <> value | rest], clean, overrides), do: command_override(value, rest, clean, overrides)
  defp command_config(["--config"], _, _), do: {:error, :model_service_command_unsafe}
  defp command_config([token | rest], clean, overrides), do: command_config(rest, [token | clean], overrides)

  defp command_override(value, rest, clean, overrides) do
    with [_, encoded] <- Regex.run(~r/\Amodel_reasoning_effort\s*=\s*(.+)\z/, value),
         effort =
           (case scalar(encoded) do
              {:ok, decoded} -> decoded
              _ -> encoded
            end),
         true <- effort in ~w(none minimal low medium high xhigh) do
      command_config(rest, clean, Map.put(overrides, {"", "model_reasoning_effort"}, effort))
    else
      _ -> {:error, :model_service_command_unsafe}
    end
  end

  defp native_fields?(config),
    do: Enum.all?(~w(openai_base_url chatgpt_base_url), fn key -> not Map.has_key?(config, {"", key}) or is_binary(config[{"", key}]) end)

  defp connection(config, provider, reference, environment) do
    builtin = Map.get(config, {"", "model_provider"}, "openai") == "openai"

    url =
      if builtin and chatgpt_reference?(reference) do
        # Codex treats this as a backend root and always appends /codex, even
        # when the administrator's root already ends in that suffix.
        String.trim_trailing(Map.get(config, {"", "chatgpt_base_url"}, "https://chatgpt.com/backend-api"), "/") <> "/codex"
      else
        native = if builtin, do: config[{"", "openai_base_url"}]
        provider["base_url"] || native || environment.("OPENAI_BASE_URL") || "https://api.openai.com/v1"
      end

    %{"base_url" => url, "protocol" => "responses"}
  end

  defp chatgpt_reference?("auth_home:" <> home), do: ModelServices.chatgpt_auth?(home)
  defp chatgpt_reference?(_), do: false

  # Legacy ExecutionSandbox generated its own config; auth_home supplied auth.json
  # only. Importing that home's provider, profiles or effort changes old execution.
  defp effective_config(_home, %{enabled: true}), do: {:ok, %{}}
  defp effective_config(home, _sandbox), do: read_config(Path.join(home, "config.toml"))

  defp read_config(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, raw} -> parse(raw)
      _ -> {:error, :legacy_config_unreadable}
    end
  end

  # Unsupported TOML is a migration stop, never an invented effective default.
  defp parse(raw) do
    raw
    |> String.split(~r/\r?\n/)
    |> Enum.reduce_while({:ok, %{}, "", MapSet.new()}, &line/2)
    |> case do
      {:ok, config, _, _} -> {:ok, config}
      error -> error
    end
  end

  defp line(raw, {:ok, config, section, tables}) do
    value = String.trim(raw)

    cond do
      value == "" or String.starts_with?(value, "#") -> {:cont, {:ok, config, section, tables}}
      String.starts_with?(value, "[") -> table(value, config, tables)
      true -> assignment(value, config, section, tables)
    end
  end

  defp table(value, config, tables) do
    with {:ok, name} <- table_name(value),
         false <- name == "profiles" or String.starts_with?(name, "profiles."),
         false <- MapSet.member?(tables, name) do
      {:cont, {:ok, config, name, MapSet.put(tables, name)}}
    else
      _ -> {:halt, {:error, :legacy_table_unsupported}}
    end
  end

  defp table_name(value) do
    case Regex.run(~r/\A\[\s*projects\s*\.\s*("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|[a-zA-Z0-9_-]+)\s*\]\s*(?:#.*)?\z/, value) do
      [_, encoded] ->
        project_table_name(encoded)

      _ ->
        simple_table_name(value)
    end
  end

  defp project_table_name(encoded) do
    # Canonicalize quoted and bare project keys so duplicate tables cannot
    # evade detection by changing quotes. Project trust is unrelated to routing.
    case scalar(encoded) do
      {:ok, path} when is_binary(path) ->
        {:ok, "projects." <> Jason.encode!(path)}

      _ ->
        if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, encoded),
          do: {:ok, "projects." <> Jason.encode!(encoded)},
          else: {:error, :legacy_table_unsupported}
    end
  end

  defp simple_table_name(value) do
    case Regex.run(~r/\A\[([a-zA-Z0-9_.-]+)\]\s*(?:#.*)?\z/, value) do
      [_, name] -> {:ok, name}
      _ -> {:error, :legacy_table_unsupported}
    end
  end

  defp assignment(value, config, section, tables) do
    with [_, key, encoded] <- Regex.run(~r/\A([a-zA-Z0-9_-]+)\s*=\s*(.+)\z/, value),
         {:ok, decoded} <- scalar(encoded),
         identity = {section, key},
         false <- Map.has_key?(config, identity),
         true <- section != "" or key in @root_keys do
      {:cont, {:ok, Map.put(config, identity, decoded), section, tables}}
    else
      _ -> {:halt, {:error, :legacy_config_unsupported}}
    end
  end

  defp scalar(value) do
    # JSON strings are a strict subset of TOML basic strings; never strip quoted '#'.
    case Regex.run(~r/\A("(?:[^"\\\n]|\\.)*"|'[^'\n]*'|true|false|[0-9]+)\s*(?:#.*)?\z/, value) do
      [_, "'" <> literal] -> {:ok, String.slice(literal, 0..-2//1)}
      [_, encoded] -> Jason.decode(encoded)
      _ -> {:error, :legacy_value_unsupported}
    end
  end

  defp provider(config) do
    id = Map.get(config, {"", "model_provider"}, "openai")
    section = "model_providers.#{id}"
    provider = Map.new(for {{^section, key}, value} <- config, do: {key, value})

    if is_binary(id) and ModelServices.identifier?(id) and
         (id == "openai" or map_size(provider) > 0) and
         Map.keys(provider) -- @provider_keys == [] and
         not Enum.any?(Map.keys(config), fn {name, _} -> String.starts_with?(name, section <> ".") end) and
         supported_protocol?(provider) do
      {:ok, Map.put_new(provider, "requires_openai_auth", id == "openai")}
    else
      {:error, :legacy_provider_unsupported}
    end
  end

  defp supported_protocol?(provider),
    do:
      Map.get(provider, "wire_api", "responses") == "responses" and
        Map.get(provider, "requires_openai_auth", true) in [true, false]

  defp reference(%{"env_key" => _, "requires_openai_auth" => true}, _, _), do: {:error, :legacy_credential_ambiguous}

  defp reference(%{"env_key" => key}, _home, _environment) when is_binary(key), do: {:ok, "env:" <> key}
  defp reference(%{"env_key" => _}, _, _), do: {:error, :legacy_credential_unsupported}

  defp reference(provider, home, environment) do
    if provider["requires_openai_auth"] == false do
      {:error, :legacy_credential_unsupported}
    else
      case Enum.find(~w(CODEX_API_KEY OPENAI_API_KEY), &(environment.(&1) not in [nil, ""])) do
        nil -> {:ok, "auth_home:" <> home}
        name -> {:ok, "env:" <> name}
      end
    end
  end

  defp parameters(config, sandbox) do
    default = if sandbox[:enabled] == true, do: "high"
    effort = Map.get(config, {"", "model_reasoning_effort"}, default)
    if is_nil(effort), do: %{}, else: %{"reasoning_effort" => effort}
  end
end
