defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  Thin GitLab REST client for project-scoped issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://gitlab.com/api/v4"
  @page_size 100

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @doc "Resolve the configured project, credential and TLS trust settings for controller use."
  @spec connection_settings(map()) :: {:ok, map()} | {:error, term()}
  def connection_settings(tracker_settings), do: settings(tracker_settings)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITLAB_PAT",
      "GITLAB_ACCESS_TOKEN",
      "GITLAB_TOKEN",
      "OAUTH_TOKEN" | env_reference_names([provider["api_key"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, query, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(query) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, gitlab_settings} <- settings(tracker_settings) do
      request_fun.(method, path, query, body, gitlab_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker_settings)
      when is_map(issue) and is_map(tracker_settings) do
    case settings(tracker_settings) do
      {:ok, gitlab_settings} -> normalize_issue(issue, gitlab_settings)
      _ -> nil
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  @spec fetch_issues_by_states([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, tracker_settings, request_fun \\ &perform_request/5) do
    fetch_state_pages(states, tracker_settings, request_fun, false)
  end

  @doc "Read issues for preflight, rejecting malformed records."
  @spec fetch_issues_by_states_strict([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_strict(states, tracker_settings, request_fun \\ &perform_request/5) do
    fetch_state_pages(states, tracker_settings, request_fun, true)
  end

  defp fetch_state_pages(states, tracker_settings, request_fun, strict?) do
    normalized_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()

    case gitlab_state_query(normalized_states) do
      nil ->
        {:ok, []}

      state_query ->
        with {:ok, gitlab_settings} <- settings(tracker_settings) do
          fetch_issue_pages(gitlab_settings, state_query, normalized_states, 1, request_fun, [], strict?)
        end
    end
  end

  defp fetch_issue_pages(settings, state_query, requested_states, page, request_fun, pages, strict?) do
    query = %{
      "state" => state_query,
      "per_page" => @page_size,
      "page" => page,
      "order_by" => "created_at",
      "sort" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             project_issues_path(settings),
             query,
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :gitlab_unknown_payload},
         :ok <- validate_page(payload, settings, strict?) do
      issues = normalize_state_page(payload, settings, requested_states)
      updated_pages = [issues | pages]

      if length(payload) < @page_size do
        {:ok, updated_pages |> Enum.reverse() |> List.flatten()}
      else
        fetch_issue_pages(settings, state_query, requested_states, page + 1, request_fun, updated_pages, strict?)
      end
    end
  end

  @spec fetch_issues_by_ids([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids, tracker_settings, request_fun \\ &perform_request/5) do
    case Enum.uniq(ids) do
      [] ->
        {:ok, []}

      unique_ids ->
        with {:ok, gitlab_settings} <- settings(tracker_settings) do
          fetch_issue_ids(unique_ids, gitlab_settings, request_fun, [])
        end
    end
  end

  defp fetch_issue_ids([], _settings, _request_fun, issues), do: {:ok, Enum.reverse(issues)}

  defp fetch_issue_ids([id | rest], settings, request_fun, issues) do
    with {:ok, iid} <- parse_iid(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             project_issue_path(settings, iid),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_issue_id_fetch(payload, rest, settings, request_fun, issues)
    end
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, request_fun, issues) do
    fetch_issue_ids(rest, settings, request_fun, issues)
  end

  defp continue_issue_id_fetch(%{} = raw_issue, rest, settings, request_fun, issues) do
    case normalize_issue(raw_issue, settings) do
      %Issue{} = issue -> fetch_issue_ids(rest, settings, request_fun, [issue | issues])
      nil -> {:error, :gitlab_unknown_payload}
    end
  end

  defp continue_issue_id_fetch(_payload, _rest, _settings, _request_fun, _issues) do
    {:error, :gitlab_unknown_payload}
  end

  defp validate_page(payload, settings, true) do
    if Enum.any?(payload, &(not valid_preflight_issue?(&1, settings))), do: {:error, :gitlab_unknown_payload}, else: :ok
  end

  defp validate_page(_, _, false), do: :ok

  defp valid_preflight_issue?(raw, settings) when is_map(raw) do
    not is_nil(normalize_issue(raw, settings)) and raw["state"] in ["opened", "closed"] and
      is_list(raw["labels"]) and Enum.all?(raw["labels"], &is_binary/1)
  end

  defp valid_preflight_issue?(_, _), do: false

  defp normalize_state_page(raw_issues, settings, requested_states) do
    issues = Enum.map(raw_issues, &normalize_issue(&1, settings))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed GitLab issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(%{"iid" => iid, "title" => title, "state" => state} = issue, settings)
       when is_integer(iid) and iid > 0 and is_binary(title) and is_binary(state) do
    if present_string?(title) and present_string?(state) do
      %Issue{
        id: Integer.to_string(iid),
        native_ref: native_ref(issue, settings),
        identifier: "GL-#{iid}",
        title: title,
        description: blank_to_nil(issue["description"]),
        priority: nil,
        state: state,
        branch_name: nil,
        url: issue["web_url"],
        assignee_id: assignee_id(issue),
        labels: extract_labels(issue["labels"]),
        blocked_by: [],
        dispatchable: true,
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _settings), do: nil

  defp native_ref(issue, settings) do
    %{
      "id" => issue["id"],
      "iid" => issue["iid"],
      "project_id" => issue["project_id"],
      "project_path" => settings.project_path,
      "repo" => settings.project_path,
      "number" => issue["iid"],
      "kind" => "gitlab",
      "api_url" => settings.api_url,
      "references" => issue["references"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp assignee_id(%{"assignees" => [assignee | _]}) when is_map(assignee), do: assignee_id(assignee)

  defp assignee_id(%{"assignee" => assignee}) when is_map(assignee), do: assignee_id(assignee)

  defp assignee_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)

  defp assignee_id(%{"username" => username}) when is_binary(username), do: username

  defp assignee_id(_assignee), do: nil

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_labels), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, query, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, query, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("GitLab API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:gitlab_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :gitlab_unknown_payload}
    end
  end

  defp perform_request(method, path, query, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: gitlab_headers(settings.api_key),
        params: query,
        retry: false,
        redirect: request_method == :get,
        connect_options: connect_options(settings)
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  defp connect_options(%{ca_file: nil}), do: [timeout: 30_000]

  defp connect_options(%{ca_file: path}) do
    trusted_ders =
      case File.read(path) do
        {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
        _ -> []
      end

    verify_fun =
      {fn
         _cert, :valid, state ->
           {:valid, state}

         _cert, :valid_peer, state ->
           {:valid, state}

         cert, {:bad_cert, :selfsigned_peer}, state ->
           raw_der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)

           if raw_der in trusted_ders do
             {:valid, state}
           else
             {:fail, :selfsigned_peer}
           end

         _cert, {:bad_cert, reason}, _state ->
           {:fail, reason}

         _cert, {:extension, _}, state ->
           # Delegate extension handling to OTP: non-critical extensions are accepted,
           # unknown critical extensions are rejected, as required by RFC 5280.
           {:unknown, state}
       end, []}

    # Note: verify_fun directly compares raw DER against trusted_ders for :selfsigned_peer.
    # Independent leaf certificates issued by an intermediate CA are not currently handled here
    # as this instance uses self-signed peer certificates.
    # Only cacerts is passed here to avoid OTP warning "cacertfile ignored, cacerts is set".
    [
      timeout: 30_000,
      transport_opts: [
        verify: :verify_peer,
        cacerts: trusted_ders,
        verify_fun: verify_fun
      ]
    ]
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    project_path = resolve_setting(provider["project_path"], System.get_env("GITLAB_PROJECT_PATH"))

    api_key = resolve_setting(provider["api_key"], System.get_env("GITLAB_PAT"))
    ca_file = resolve_setting(provider["ca_file"], nil)

    cond do
      not valid_api_url?(api_url) ->
        {:error, :invalid_gitlab_api_url}

      not present_string?(project_path) ->
        {:error, :missing_gitlab_project_path}

      not valid_project_path?(project_path) ->
        {:error, :invalid_gitlab_project_path}

      not is_nil(provider["ca_file"]) and not valid_ca_file?(ca_file) ->
        {:error, :invalid_gitlab_ca_file}

      not present_string?(api_key) ->
        {:error, :missing_gitlab_api_key}

      true ->
        {:ok,
         %{
           api_url: String.trim_trailing(api_url, "/"),
           api_key: api_key,
           project_path: project_path,
           ca_file: ca_file
         }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, _fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name))
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_ca_file?(path) when is_binary(path) do
    case File.read(path) do
      {:ok, pem} -> Enum.any?(:public_key.pem_decode(pem), &match?({:Certificate, _, _}, &1))
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_ca_file?(_), do: false

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false

  defp valid_project_path?(value) when is_binary(value) do
    String.match?(value, ~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/) and
      Enum.all?(String.split(value, "/"), &(&1 not in [".", ".."]))
  end

  defp valid_project_path?(_value), do: false

  defp project_issues_path(settings), do: "/projects/#{encoded(settings.project_path)}/issues"

  defp project_issue_path(settings, iid), do: "#{project_issues_path(settings)}/#{iid}"

  defp gitlab_headers(api_key) do
    [
      {"Accept", "application/json"},
      {"Authorization", "Bearer " <> api_key}
    ]
  end

  defp gitlab_state_query(states) do
    has_opened? = MapSet.member?(states, "opened")
    has_closed? = MapSet.member?(states, "closed")

    cond do
      has_opened? and has_closed? -> "all"
      has_opened? -> "opened"
      has_closed? -> "closed"
      true -> nil
    end
  end

  defp parse_iid(value) when is_binary(value) do
    case Integer.parse(value) do
      {iid, ""} when iid > 0 -> {:ok, iid}
      _ -> {:error, :invalid_gitlab_issue_id}
    end
  end

  defp parse_iid(_value), do: {:error, :invalid_gitlab_issue_id}

  defp encoded(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_gitlab_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
