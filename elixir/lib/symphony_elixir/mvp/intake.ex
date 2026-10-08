defmodule SymphonyElixir.Mvp.Intake do
  @moduledoc """
  Resolves an authorized ready event and model choices for one GitHub issue.
  """

  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Mvp.{ModelCatalog, ModelServices}
  alias SymphonyElixir.Tracker.Issue

  @page_size 100
  @command_prefix "/symphony"
  @assignment ~r/\A(?<role>[A-Za-z][A-Za-z0-9_-]*)=(?<model>[A-Za-z0-9][A-Za-z0-9._:\/+-]*)\z/
  @command ~r/\A\/symphony (?<kind>models|configs) (?<assignments>\S+(?: \S+)*)\z/

  @type model_choice :: %{coder: String.t(), reviewer: String.t()}

  def resolve(issue, settings, opts \\ [])

  @spec resolve(Issue.t() | map(), map(), keyword()) :: {:ok, model_choice()} | {:error, term()}
  def resolve(issue, settings, opts) when is_map(settings) and is_list(opts) do
    with :ok <- enabled(settings) do
      resolve_authorized(issue, settings, opts)
    end
  end

  def resolve(_issue, _settings, _opts), do: {:error, :invalid_mvp_settings}

  @doc "Revalidate ready authorization and model comments for an already claimed task."
  def resolve_claimed(issue, settings, opts \\ [])

  @spec resolve_claimed(Issue.t() | map(), map(), keyword()) :: {:ok, model_choice()} | {:error, term()}
  def resolve_claimed(issue, settings, opts) when is_map(settings) and is_list(opts) do
    resolve_authorized(issue, settings, opts)
  end

  def resolve_claimed(_issue, _settings, _opts), do: {:error, :invalid_mvp_settings}

  defp resolve_authorized(issue, settings, opts) do
    with :ok <- validate_settings(settings),
         {:ok, reference} <- issue_reference(issue),
         :ok <- ready_issue(issue, Map.get(settings, :ready_label, "ready")),
         {:ok, events} <- fetch_pages(reference, "events", opts),
         :ok <-
           authorized_ready_actor(
             events,
             Map.get(settings, :ready_label, "ready"),
             Map.get(settings, :allowed_actors)
           ),
         {:ok, comments} <- fetch_pages(reference, "comments", opts) do
      resolve_comments(comments, settings)
    end
  end

  @spec ready?(term(), String.t()) :: boolean()
  def ready?(issue, ready_label), do: ready_issue(issue, ready_label) == :ok

  @spec resolve_comments([map()], map()) :: {:ok, model_choice()} | {:error, term()}
  def resolve_comments(comments, settings) when is_list(comments) and is_map(settings) do
    with :ok <- validate_settings(settings),
         {:ok, defaults} <- defaults(settings) do
      with {:ok, selected} <- apply_comments(comments, defaults, settings, MapSet.new(settings.allowed_actors)), :ok <- validate_selected(selected, settings), do: {:ok, selected}
    end
  end

  def resolve_comments(_comments, _settings), do: {:error, :invalid_comments}

  defp validate_selected(%{services: services}, settings) do
    Enum.reduce_while(services, :ok, fn {_, service}, :ok ->
      case ModelCatalog.available(settings.model_services, service) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_selected(_, _), do: :ok

  defp enabled(%{enabled: true}), do: :ok
  defp enabled(%{enabled: false}), do: {:error, :mvp_disabled}
  defp enabled(_settings), do: {:error, :invalid_mvp_settings}

  defp validate_settings(settings) do
    allowed_models = Map.get(settings, :allowed_models)
    allowed_actors = Map.get(settings, :allowed_actors)
    ready_label = Map.get(settings, :ready_label, "ready")

    if valid_name_list?(allowed_models) and valid_name_list?(allowed_actors) and
         is_binary(ready_label) and String.trim(ready_label) != "" do
      :ok
    else
      {:error, :invalid_mvp_settings}
    end
  end

  defp valid_name_list?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) and
      length(values) == length(Enum.uniq(values))
  end

  defp valid_name_list?(_values), do: false

  defp defaults(%{model_services: registry} = settings) when is_map(registry) do
    with {:ok, coder} <- ModelServices.default_snapshot(settings, :coder, "project_default"),
         {:ok, reviewer} <- ModelServices.default_snapshot(settings, :reviewer, "project_default"),
         do: {:ok, %{coder: coder["model"], reviewer: reviewer["model"], services: %{"coder" => coder, "reviewer" => reviewer}}}
  end

  defp defaults(settings) do
    coder = Map.get(settings, :coder_model)
    reviewer = Map.get(settings, :reviewer_model)
    allowed = MapSet.new(Map.get(settings, :allowed_models, []))

    if valid_model?(coder, allowed) and valid_model?(reviewer, allowed) do
      {:ok, %{coder: coder, reviewer: reviewer}}
    else
      {:error, :invalid_mvp_default_model}
    end
  end

  defp valid_model?(model, allowed) when is_binary(model), do: MapSet.member?(allowed, model)
  defp valid_model?(_model, _allowed), do: false

  defp issue_reference(%Issue{native_ref: native_ref}), do: issue_reference(native_ref)

  defp issue_reference(%{"repo" => repo, "number" => number}), do: normalized_reference(repo, number)
  defp issue_reference(%{repo: repo, number: number}), do: normalized_reference(repo, number)
  defp issue_reference(%{"repository" => %{"full_name" => repo}, "number" => number}), do: normalized_reference(repo, number)
  defp issue_reference(%{repository: %{full_name: repo}, number: number}), do: normalized_reference(repo, number)
  defp issue_reference(_issue), do: {:error, :invalid_issue_reference}

  defp normalized_reference(repo, number) when is_binary(repo) do
    case issue_number(number) do
      {:ok, parsed_number} ->
        case String.split(repo, "/", parts: 3) do
          [owner, name] when owner != "" and name != "" ->
            {:ok, %{repo: repo, number: parsed_number}}

          _ ->
            {:error, :invalid_issue_reference}
        end

      error ->
        error
    end
  end

  defp normalized_reference(_repo, _number), do: {:error, :invalid_issue_reference}

  defp issue_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_issue_reference}
    end
  end

  defp issue_number(_number), do: {:error, :invalid_issue_reference}

  defp ready_issue(%Issue{dispatchable: true, state: "open", labels: labels}, ready_label)
       when is_list(labels) and is_binary(ready_label) do
    if Enum.any?(labels, &label_matches?(&1, ready_label)), do: :ok, else: {:error, :issue_not_ready}
  end

  defp ready_issue(%{"state" => "open", "labels" => labels}, ready_label) when is_list(labels) do
    if Enum.any?(labels, &label_matches?(&1, ready_label)), do: :ok, else: {:error, :issue_not_ready}
  end

  defp ready_issue(%{state: "open", labels: labels}, ready_label) when is_list(labels) do
    if Enum.any?(labels, &label_matches?(&1, ready_label)), do: :ok, else: {:error, :issue_not_ready}
  end

  defp ready_issue(_issue, _ready_label), do: {:error, :issue_not_ready}

  defp label_matches?(%{"name" => name}, ready_label), do: label_matches?(name, ready_label)
  defp label_matches?(%{name: name}, ready_label), do: label_matches?(name, ready_label)

  defp label_matches?(name, ready_label) when is_binary(name) and is_binary(ready_label),
    do: String.downcase(name) == String.downcase(ready_label)

  defp label_matches?(_name, _ready_label), do: false

  defp fetch_pages(reference, resource, opts) do
    path = issue_resource_path(reference, resource)
    fetch_page(path, 1, opts, [])
  end

  defp fetch_page(path, page, opts, acc) do
    params = %{"per_page" => @page_size, "page" => page}

    with {:ok, payload} <- request("GET", path, params, opts),
         true <- is_list(payload) or {:error, :github_unknown_payload} do
      updated = [payload | acc]

      if length(payload) < @page_size do
        {:ok, updated |> Enum.reverse() |> List.flatten()}
      else
        fetch_page(path, page + 1, opts, updated)
      end
    end
  end

  defp request(method, path, params, opts) do
    client_opts =
      []
      |> maybe_put(:request_fun, Keyword.get(opts, :request_fun))
      |> maybe_put(:tracker_settings, Keyword.get(opts, :tracker_settings))

    case GitHubClient.request(method, path, params, nil, client_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp issue_resource_path(%{repo: repo, number: number}, resource) do
    encoded_repo =
      repo
      |> String.split("/", parts: 2)
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "/repos/#{encoded_repo}/issues/#{number}/#{resource}"
  end

  defp authorized_ready_actor(events, ready_label, allowed_actors)
       when is_list(events) and is_binary(ready_label) and is_list(allowed_actors) do
    latest =
      events
      |> Enum.filter(&ready_labeled_event?(&1, ready_label))
      |> Enum.max_by(&event_order/1, fn -> nil end)

    case latest do
      %{"actor" => %{"login" => login}} when is_binary(login) ->
        if login in allowed_actors, do: :ok, else: {:error, {:unauthorized_ready_actor, login}}

      _ ->
        {:error, :ready_label_event_not_found}
    end
  end

  defp ready_labeled_event?(%{"event" => "labeled", "label" => label}, ready_label),
    do: label_matches?(label, ready_label)

  defp ready_labeled_event?(_event, _ready_label), do: false

  defp event_order(%{"id" => id}) when is_integer(id), do: id

  defp event_order(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp event_order(_event), do: -1

  defp apply_comments(comments, defaults, settings, allowed_actors) do
    indexed =
      comments
      |> Enum.with_index()
      |> Enum.filter(fn {comment, _index} -> is_map(comment) end)
      |> Enum.sort_by(fn {comment, index} -> comment_order(comment, index) end)

    Enum.reduce_while(indexed, {:ok, defaults}, fn {comment, _index}, {:ok, selected} ->
      apply_comment(comment, selected, settings, allowed_actors)
    end)
  end

  defp apply_comment(comment, selected, settings, allowed_actors) do
    case authorized_comment_command(comment, allowed_actors) do
      :ignore ->
        {:cont, {:ok, selected}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      {:ok, kind, assignments} ->
        apply_assignments_result(kind, assignments, selected, settings, comment)
    end
  end

  defp apply_assignments_result(kind, assignments, selected, settings, comment) do
    source = "issue_comment:#{comment["id"]}:#{comment["user"]["login"]}:#{kind}"
    result = role_assignments(kind, assignments, selected, settings, source)

    case result do
      {:ok, updated} -> {:cont, {:ok, updated}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp role_assignments(kind, assignments, selected, %{model_services: registry} = settings, source) when is_map(registry) do
    Enum.reduce_while(assignments, {:ok, selected}, fn {role, value}, {:ok, acc} ->
      result =
        if kind == "configs" or value == "default",
          do: ModelServices.select(settings, role, value, source, acc),
          else: ModelServices.select_model(settings, role, value, source, acc)

      selection_result(result)
    end)
  end

  defp role_assignments("configs", _, _, _, _), do: {:error, :model_services_not_configured}

  defp role_assignments(_, assignments, selected, settings, _),
    do: apply_assignments(assignments, selected, MapSet.new(settings.allowed_models))

  defp selection_result({:ok, updated}), do: {:cont, {:ok, updated}}
  defp selection_result(error), do: {:halt, error}

  defp comment_order(comment, index) do
    case integer_id(comment["id"]) do
      {:ok, id} -> {0, id, index}
      :error -> {1, index, index}
    end
  end

  defp authorized_comment_command(comment, allowed_actors) do
    user =
      case comment["user"] do
        user when is_map(user) -> user
        _ -> %{}
      end

    login = Map.get(user, "login")
    body = comment["body"]

    cond do
      not is_binary(login) ->
        :ignore

      bot?(user, login) ->
        :ignore

      login not in allowed_actors ->
        :ignore

      not is_binary(body) or not command_candidate?(body) ->
        :ignore

      true ->
        parse_command(body, comment["id"])
    end
  end

  defp bot?(user, login) do
    user["type"] == "Bot" or String.ends_with?(String.downcase(login), "[bot]")
  end

  defp command_candidate?(body) do
    trimmed = String.trim_leading(body)
    trimmed == @command_prefix or String.starts_with?(trimmed, @command_prefix <> " ")
  end

  defp parse_command(body, comment_id) do
    if integer_id(comment_id) == :error do
      {:error, {:missing_model_command_id, comment_id}}
    else
      case Regex.named_captures(@command, body) do
        %{"kind" => kind, "assignments" => assignments} ->
          parse_kind_assignments(kind, assignments, comment_id)

        _ ->
          {:error, {:malformed_model_command, comment_id}}
      end
    end
  end

  defp parse_kind_assignments(kind, assignments, id) do
    with {:ok, parsed} <- parse_assignments(String.split(assignments, " "), id), do: {:ok, kind, parsed}
  end

  defp parse_assignments(tokens, comment_id) do
    Enum.reduce_while(tokens, {:ok, %{}}, fn token, {:ok, assignments} ->
      parse_assignment(token, assignments, comment_id)
    end)
  end

  defp parse_assignment(token, assignments, comment_id) do
    case Regex.named_captures(@assignment, token) do
      %{"role" => raw_role, "model" => model} ->
        role = role_atom(raw_role)

        cond do
          is_nil(role) ->
            {:halt, {:error, {:unknown_model_role, raw_role, comment_id}}}

          Map.has_key?(assignments, role) ->
            {:halt, {:error, {:duplicate_model_role, role, comment_id}}}

          true ->
            {:cont, {:ok, Map.put(assignments, role, model)}}
        end

      _ ->
        {:halt, {:error, {:malformed_model_command, comment_id}}}
    end
  end

  defp role_atom("coder"), do: :coder
  defp role_atom("reviewer"), do: :reviewer
  defp role_atom(_role), do: nil

  defp apply_assignments(assignments, selected, allowed_models) do
    case Enum.find(assignments, fn {_role, model} -> not MapSet.member?(allowed_models, model) end) do
      {_role, model} ->
        {:error, {:model_not_allowed, model}}

      nil ->
        {:ok, Map.merge(selected, assignments)}
    end
  end

  defp integer_id(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp integer_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp integer_id(_value), do: :error
end
