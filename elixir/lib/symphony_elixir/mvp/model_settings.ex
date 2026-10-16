defmodule SymphonyElixir.Mvp.ModelSettings do
  @moduledoc "Repository-scoped default management. No scheduler, task or global workflow mutations."
  alias SymphonyElixir.Mvp.{Config, ModelCatalog, ModelServices}
  alias SymphonyElixir.{PathSafety, Workflow}

  @spec load(Path.t()) :: {:ok, map()} | {:error, atom()}
  def load(path) do
    with {:ok, raw} <- File.read(path), {:ok, config} <- Jason.decode(raw), :ok <- validate(config) do
      {:ok, config}
    else
      _ -> {:error, :invalid_model_settings_config}
    end
  end

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(config) do
    if is_map(config) and Enum.sort(Map.keys(config)) == ~w(origin port repositories token_ref) and
         is_integer(config["port"]) and config["port"] in 0..65_535 and valid_origin?(config["origin"]) and
         is_binary(config["token_ref"]) and Regex.match?(~r/\Aenv:[A-Z][A-Z0-9_]*\z/, config["token_ref"]) and
         valid_repositories?(config["repositories"]), do: :ok, else: {:error, :invalid_model_settings_config}
  end

  defp valid_origin?(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, ""]
  end

  defp valid_origin?(_), do: false

  defp valid_repositories?(repos) when is_map(repos) and map_size(repos) > 0 do
    Enum.all?(repos, fn {id, repo} -> ModelServices.identifier?(id) and valid_repository?(repo) end) and
      unique?(repos, "workflow") and unique?(repos, "state_dir") and unique?(repos, "repository")
  end

  defp valid_repositories?(_), do: false
  defp unique?(repos, field), do: repos |> Map.values() |> Enum.map(& &1[field]) |> then(&(length(&1) == length(Enum.uniq(&1))))

  defp valid_repository?(repo) when is_map(repo) do
    Enum.sort(Map.keys(repo)) == ~w(repository state_dir workflow) and
      is_binary(repo["repository"]) and
      Enum.all?(String.split(repo["repository"], "/"), &(&1 not in [".", ".."])) and Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/, repo["repository"]) and
      Enum.all?(~w(workflow state_dir), &absolute?(repo[&1]))
  end

  defp valid_repository?(_), do: false
  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path

  @spec settings(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def settings(config, id) do
    with %{} = repo <- config["repositories"][id],
         {:ok, workflow_path} <- PathSafety.canonicalize(repo["workflow"]),
         true <- workflow_path == repo["workflow"],
         {:ok, workflow} <- Workflow.load(workflow_path),
         true <- repository_matches?(workflow.config, repo["repository"]),
         {:ok, settings} <- Config.execution_settings(workflow, Path.dirname(workflow_path)),
         {:ok, state_dir} <- PathSafety.canonicalize(settings.state_dir),
         true <- state_dir == repo["state_dir"] and is_map(settings.model_services) do
      version = :crypto.hash(:sha256, :erlang.term_to_binary({repo, workflow.config}, [:deterministic])) |> Base.encode16(case: :lower)
      {:ok, Map.put(settings, :workflow_version, version)}
    else
      _ -> {:error, :model_settings_repository_unavailable}
    end
  end

  defp repository_matches?(%{"tracker" => %{"kind" => "gitlab", "provider" => provider}}, expected) when is_map(provider) do
    project =
      case provider["project_path"] do
        "$" <> name -> System.get_env(name)
        nil -> System.get_env("GITLAB_PROJECT_PATH")
        value -> value
      end

    is_binary(project) and String.trim(project) == expected
  end

  defp repository_matches?(%{"tracker" => %{"provider" => %{"repo" => repository}}}, expected) do
    repository == expected
  end

  defp repository_matches?(_, _), do: false

  @spec show(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def show(config, id) do
    with {:ok, settings} <- settings(config, id), do: present(settings, config["repositories"][id]["repository"])
  end

  defp present(settings, repository) do
    with {:ok, coder} <- ModelServices.default_snapshot(settings, :coder, "settings"),
         {:ok, reviewer} <- ModelServices.default_snapshot(settings, :reviewer, "settings") do
      roles = Map.new([:coder, :reviewer], &{Atom.to_string(&1), choices(settings, &1)})

      effective =
        Map.new([coder, reviewer], fn service ->
          {service["role"], %{"preset" => service["id"], "model" => service["model"], "parameters" => service["parameters"]}}
        end)

      {:ok,
       %{
         "effective_defaults" => effective,
         "repository" => repository,
         "revision" => settings.model_services["revision"],
         "workflow_version" => settings.workflow_version,
         "defaults" => settings.model_services["defaults"],
         "roles" => roles
       }}
    end
  end

  defp choices(settings, role) do
    Enum.flat_map(settings.model_services["presets"], fn {id, preset} ->
      {:ok, template} = ModelServices.snapshot(settings, id, role, "settings")
      models = get_in(settings.model_services, ["catalog", id, "models"]) || %{}
      Enum.flat_map(models, &model_choices(settings.model_services, template, preset, &1))
    end)
  end

  defp model_choices(registry, template, preset, {model, metadata}) do
    discovery = metadata["discovery"][ModelServices.channel_binding(template)] || %{"reasoning_mode" => "unknown"}
    efforts = discovery["reasoning_efforts"] || []
    parameters = if efforts == [], do: [%{}], else: Enum.map(efforts, &%{"reasoning_effort" => &1})
    legacy_null = template["provider"] == "openai" and model == template["model"] and template["parameters"] == %{"reasoning_effort" => nil}
    parameters = if legacy_null, do: parameters ++ [template["parameters"]], else: parameters

    Enum.map(parameters, fn parameters ->
      service = template |> Map.put("model", model) |> Map.put("parameters", parameters)
      status = ModelCatalog.status(registry, service)
      selection = %{"preset" => template["id"], "model" => model, "parameters" => parameters}

      %{
        "selection" => selection,
        "default_value" => if(legacy_null and parameters == template["parameters"], do: template["id"], else: selection),
        "provider" => preset["provider"],
        "credential_ref" => safe_reference(preset["credential_ref"]),
        "version" => preset["version"],
        "reasoning_mode" => reasoning_mode(discovery, efforts),
        "state" => status["state"],
        "reason" => status["reason"],
        "validation" => status["validation"]
      }
    end)
  end

  defp safe_reference("auth_home:" <> _), do: "auth_home:(configured)"
  defp safe_reference(reference), do: reference

  defp reasoning_mode(%{"reasoning_mode" => mode}, _), do: mode
  defp reasoning_mode(_, []), do: "fixed"
  defp reasoning_mode(_, _), do: "effort"

  @spec save(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def save(config, id, request) do
    with true <- (is_map(request) and Enum.sort(Map.keys(request)) == ~w(defaults revision workflow_version)) or {:error, :invalid_model_settings_request},
         true <- (is_integer(request["revision"]) and request["revision"] >= 0) or {:error, :invalid_model_settings_request},
         {:ok, settings} <- settings(config, id),
         true <- request["workflow_version"] == settings.workflow_version or {:error, :model_services_conflict},
         proposed = Map.put(settings.model_services, "defaults", request["defaults"]),
         :ok <- ModelServices.validate(proposed),
         :ok <- authorize_defaults(settings, proposed),
         {:ok, updated} <- ModelServices.save(ModelServices.path(settings), settings.model_services, request["revision"], proposed, settings.model_command) do
      present(Map.put(settings, :model_services, updated), config["repositories"][id]["repository"])
    end
  end

  defp authorize_defaults(settings, proposed) do
    settings = Map.put(settings, :model_services, proposed)

    Enum.reduce_while([:coder, :reviewer], :ok, fn role, :ok ->
      with {:ok, service} <- ModelServices.default_snapshot(settings, role, "settings"),
           :ok <- ModelCatalog.available(proposed, service) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
