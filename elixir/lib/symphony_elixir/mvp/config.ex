defmodule SymphonyElixir.Mvp.Config do
  @moduledoc "Configuration for the opt-in GitHub MVP intake path."

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Mvp.Recovery
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workflow

  @keys ~w(enabled coder_model reviewer_model allowed_models allowed_actors checks state_dir check_timeout_ms max_rework ready_label recovery)
  @shell_names ["sh", "bash", "dash", "zsh", "cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe"]

  @type settings :: %{
          configured: boolean(),
          enabled: boolean(),
          coder_model: String.t() | nil,
          reviewer_model: String.t() | nil,
          allowed_models: [String.t()],
          allowed_actors: [String.t()],
          checks: [[String.t()]],
          state_dir: Path.t() | nil,
          check_timeout_ms: pos_integer(),
          max_rework: 0..5,
          recovery: map(),
          ready_label: String.t()
        }

  @spec settings() :: {:ok, settings()} | {:error, term()}
  def settings do
    with {:ok, workflow} <- Workflow.current(),
         {:ok, settings} <-
           validate_mvp_config(
             Map.get(workflow.config, "mvp", %{}),
             workflow.config,
             workflow_dir()
           ) do
      {:ok, Map.put(settings, :configured, Map.has_key?(workflow.config, "mvp"))}
    end
  end

  defp validate_mvp_config(config, workflow_config, workflow_dir) when is_map(config) do
    unknown = Map.keys(config) -- @keys
    enabled = Map.get(config, "enabled", false)

    cond do
      unknown != [] ->
        {:error, {:unknown_mvp_config_fields, Enum.sort(unknown)}}

      not is_boolean(enabled) ->
        {:error, :invalid_mvp_enabled}

      true ->
        if enabled do
          enabled_settings(config, workflow_config, workflow_dir)
        else
          disabled_settings(config)
        end
    end
  end

  defp validate_mvp_config(_config, _workflow_config, _workflow_dir), do: {:error, :invalid_mvp_config}

  defp disabled_settings(config) do
    with {:ok, ready_label} <- label(Map.get(config, "ready_label", "ready")),
         {:ok, check_timeout_ms} <- positive_integer(Map.get(config, "check_timeout_ms", 300_000)),
         :ok <- max_rework(Map.get(config, "max_rework", 0)),
         {:ok, recovery} <- Recovery.settings(config["recovery"]) do
      {:ok,
       %{
         enabled: false,
         coder_model: nil,
         reviewer_model: nil,
         allowed_models: [],
         allowed_actors: [],
         checks: [],
         state_dir: nil,
         check_timeout_ms: check_timeout_ms,
         max_rework: Map.get(config, "max_rework", 0),
         recovery: recovery,
         ready_label: ready_label
       }}
    end
  end

  defp enabled_settings(config, workflow_config, workflow_dir) do
    with {:ok, coder_model} <- required_string(config, "coder_model"),
         {:ok, reviewer_model} <- required_string(config, "reviewer_model"),
         {:ok, allowed_models} <- string_list(config["allowed_models"], :allowed_models),
         :ok <- defaults_allowed([coder_model, reviewer_model], allowed_models),
         {:ok, allowed_actors} <- string_list(config["allowed_actors"], :allowed_actors),
         {:ok, checks} <- checks(config["checks"]),
         {:ok, state_dir} <- state_dir(config["state_dir"], workflow_dir),
         {:ok, check_timeout_ms} <- positive_integer(Map.get(config, "check_timeout_ms", 300_000)),
         :ok <- max_rework(Map.get(config, "max_rework", 0)),
         {:ok, recovery} <- Recovery.settings(config["recovery"]),
         {:ok, ready_label} <- label(Map.get(config, "ready_label", "ready")),
         :ok <- required_ready_label(workflow_config, ready_label),
         :ok <- validate_path_boundaries(state_dir, workflow_config) do
      {:ok,
       %{
         enabled: true,
         coder_model: coder_model,
         reviewer_model: reviewer_model,
         allowed_models: allowed_models,
         allowed_actors: allowed_actors,
         checks: checks,
         state_dir: state_dir,
         check_timeout_ms: check_timeout_ms,
         max_rework: Map.get(config, "max_rework", 0),
         recovery: recovery,
         ready_label: ready_label
       }}
    end
  end

  defp required_string(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) ->
        cond do
          String.trim(value) == "" ->
            {:error, {:missing_mvp_setting, String.to_atom(key)}}

          value != String.trim(value) or String.match?(value, ~r/\s/) ->
            {:error, {:invalid_mvp_setting, String.to_atom(key)}}

          true ->
            {:ok, value}
        end

      _ ->
        {:error, {:missing_mvp_setting, String.to_atom(key)}}
    end
  end

  defp string_list(value, field) when is_list(value) and value != [] do
    if Enum.all?(value, &(is_binary(&1) and String.trim(&1) != "" and not String.match?(&1, ~r/\s/))) and
         length(value) == length(Enum.uniq(value)) do
      {:ok, value}
    else
      {:error, {:invalid_mvp_setting, field}}
    end
  end

  defp string_list(_value, field), do: {:error, {:invalid_mvp_setting, field}}

  defp defaults_allowed(models, allowed_models) do
    if Enum.all?(models, &(&1 in allowed_models)) do
      :ok
    else
      {:error, :mvp_default_model_not_allowed}
    end
  end

  defp checks(value) when is_list(value) and value != [] do
    if Enum.all?(value, &valid_argv?/1) do
      {:ok, value}
    else
      {:error, :invalid_mvp_checks}
    end
  end

  defp checks(_value), do: {:error, :invalid_mvp_checks}

  defp valid_argv?(argv) when is_list(argv) and argv != [] do
    Enum.all?(argv, &(is_binary(&1) and String.trim(&1) != "")) and
      String.downcase(Path.basename(hd(argv))) not in @shell_names and
      not Enum.any?(argv, &String.contains?(&1, ["\n", "\r"]))
  end

  defp valid_argv?(_argv), do: false

  defp state_dir(value, workflow_dir) when is_binary(value) do
    if value != "" and value == String.trim(value) do
      expanded = Path.expand(value, workflow_dir)

      case PathSafety.canonicalize(expanded) do
        {:ok, canonical} -> {:ok, canonical}
        {:error, reason} -> {:error, {:invalid_mvp_state_dir, reason}}
      end
    else
      {:error, {:missing_mvp_setting, :state_dir}}
    end
  end

  defp state_dir(_value, _workflow_dir), do: {:error, {:missing_mvp_setting, :state_dir}}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_mvp_check_timeout_ms}

  defp max_rework(value) when is_integer(value) and value in 0..5, do: :ok
  defp max_rework(_value), do: {:error, :mvp_rework_not_supported}

  defp label(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_mvp_ready_label}, else: {:ok, value}
  end

  defp label(_value), do: {:error, :invalid_mvp_ready_label}

  defp required_ready_label(workflow_config, ready_label) do
    required_labels = get_in(workflow_config, ["tracker", "required_labels"]) || []

    if is_list(required_labels) and
         Enum.any?(required_labels, fn label ->
           is_binary(label) and String.downcase(label) == String.downcase(ready_label)
         end) do
      :ok
    else
      {:error, :mvp_ready_label_not_required}
    end
  end

  defp validate_path_boundaries(state_dir, workflow_config) do
    with {:ok, workspace_root} <- workspace_root(workflow_config),
         {:ok, source_root} <- PathSafety.canonicalize(source_root()),
         :ok <- disjoint(state_dir, workspace_root, :mvp_state_workspace_overlap),
         :ok <- disjoint(state_dir, source_root, :mvp_state_source_overlap),
         :ok <- disjoint_runtime(state_dir, :mvp_state_runtime_overlap),
         :ok <- disjoint(workspace_root, source_root, :mvp_workspace_source_overlap) do
      disjoint_runtime(workspace_root, :mvp_workspace_runtime_overlap)
    end
  end

  defp workspace_root(workflow_config) do
    with {:ok, settings} <- Schema.parse(workflow_config),
         {:ok, canonical} <- PathSafety.canonicalize(settings.workspace.root) do
      {:ok, canonical}
    else
      {:error, reason} ->
        {:error, {:invalid_workspace_root, reason}}
    end
  end

  defp disjoint(left, right, error) do
    if overlaps?(left, right), do: {:error, error}, else: :ok
  end

  defp disjoint_runtime(path, error) do
    case :code.lib_dir(:symphony_elixir) do
      runtime_path when is_list(runtime_path) ->
        with {:ok, canonical} <- runtime_root(List.to_string(runtime_path)) do
          disjoint(path, canonical, error)
        end

      _ ->
        {:error, :mvp_runtime_path_unavailable}
    end
  end

  @doc false
  @spec runtime_root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def runtime_root(runtime_path) do
    archive = Path.dirname(runtime_path)

    # In an escript, lib_dir points inside the archive, not to a filesystem
    # directory. Protect the real archive's containing directory, resolving
    # symlinks before taking its parent; keep normal OTP paths unchanged.
    cond do
      File.regular?(archive) ->
        with {:ok, canonical_archive} <- PathSafety.canonicalize(archive) do
          {:ok, Path.dirname(canonical_archive)}
        end

      File.dir?(runtime_path) ->
        PathSafety.canonicalize(runtime_path)

      true ->
        {:error, :mvp_runtime_path_unavailable}
    end
  end

  defp overlaps?(left, right) do
    expanded_left = Path.expand(left)
    expanded_right = Path.expand(right)

    within?(expanded_left, expanded_right) or within?(expanded_right, expanded_left)
  end

  defp within?(path, root) do
    relative = Path.relative_to(path, root)

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../") and not String.starts_with?(relative, "..\\"))
  end

  defp source_root, do: Path.expand("../../../../", __DIR__)

  defp workflow_dir do
    Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
  end
end
