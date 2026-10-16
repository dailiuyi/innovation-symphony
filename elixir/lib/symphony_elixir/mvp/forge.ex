defmodule SymphonyElixir.Mvp.Forge do
  @moduledoc "Provider-specific transport for controller-owned issue reads and delivery. Saved pull identities retain their existing shape."

  alias SymphonyElixir.GitHub.Client, as: GitHub
  alias SymphonyElixir.GitLab.Client, as: GitLab

  @spec gitlab?(keyword()) :: boolean()
  def gitlab?(opts), do: Map.get(Keyword.get(opts, :tracker_settings, %{}), :kind) == "gitlab"

  @spec repository(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def repository(issue, opts) do
    repo = issue.native_ref["repo"]

    if gitlab?(opts) do
      with {:ok, settings} <- scope(repo, opts),
           {:ok, project} <- project_identity(repo, opts),
           true <- is_binary(project["default_branch"]) and project["default_branch"] != "" do
        {:ok, %{repo: repo, base: project["default_branch"], url: web_root(settings.api_url) <> "/#{repo}.git"}}
      else
        _ -> {:error, :mvp_repository_lookup_failed}
      end
    else
      with {:ok, %{status: 200, body: body}} <- GitHub.request("GET", "/repos/#{repo}", %{}, nil, opts),
           true <- body["full_name"] == repo and is_binary(body["default_branch"]) do
        {:ok, %{repo: repo, base: body["default_branch"], url: "https://github.com/#{repo}.git"}}
      else
        _ -> {:error, :mvp_repository_lookup_failed}
      end
    end
  end

  @spec issue(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(issue, opts), do: request("GET", issue.native_ref["repo"], issue.id, "", %{}, nil, opts)

  @spec comments(String.t(), String.t(), String.t(), map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def comments(method, repo, iid, query, body, opts), do: request(method, repo, iid, "/comments", query, body, opts)

  @doc "Read frozen issues for external handoff resume through the configured forge."
  @spec fetch_issues_by_ids(String.t(), map(), function() | nil) :: {:ok, [map()]} | {:error, term()}
  def fetch_issues_by_ids(issue_id, tracker_settings, request_fun) do
    client = client(tracker_settings)

    if request_fun do
      client.fetch_issues_by_ids([issue_id], tracker_settings, request_fun)
    else
      client.fetch_issues_by_ids([issue_id], tracker_settings)
    end
  end

  @doc "Read issues for preflight through the configured forge."
  @spec fetch_issues_by_states_strict([String.t()], map()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issues_by_states_strict(states, tracker_settings), do: client(tracker_settings).fetch_issues_by_states_strict(states, tracker_settings)

  defp request(method, repo, iid, suffix, query, body, opts) do
    if gitlab?(opts) do
      request_gitlab(method, repo, iid, suffix, query, body, opts)
    else
      GitHub.request(method, "/repos/#{repo}/issues/#{iid}" <> suffix, query, body, opts)
    end
  end

  defp request_gitlab(method, repo, iid, suffix, query, body, opts) do
    suffix = if suffix == "/comments", do: "/notes", else: suffix

    with {:ok, _settings} <- scope(repo, opts) do
      GitLab.request(method, project_path(repo) <> "/issues/#{iid}" <> suffix, query, body, opts)
    end
  end

  @spec pulls(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def pulls(repo, branch, opts) do
    if gitlab?(opts) do
      with {:ok, _settings} <- scope(repo, opts),
           {:ok, project} <- project_identity(repo, opts) do
        pull_pages(repo, project["id"], branch, opts, 1, [])
      end
    else
      owner = repo |> String.split("/") |> hd()

      case GitHub.request("GET", "/repos/#{repo}/pulls", %{"head" => "#{owner}:#{branch}", "state" => "all", "per_page" => 100}, nil, opts) do
        {:ok, %{status: 200, body: pulls}} when is_list(pulls) -> {:ok, pulls}
        _ -> {:error, :mvp_pull_lookup_failed}
      end
    end
  end

  defp pull_pages(repo, project_id, branch, opts, page, acc) when page <= 100 do
    query = %{"source_branch" => branch, "state" => "all", "scope" => "all", "per_page" => 100, "page" => page}

    case GitLab.request("GET", project_path(repo) <> "/merge_requests", query, nil, opts) do
      {:ok, %{status: 200, body: pulls}} when is_list(pulls) ->
        collect_page(pulls, repo, project_id, branch, opts, page, acc)

      _ ->
        {:error, :mvp_pull_lookup_failed}
    end
  end

  defp pull_pages(_, _, _, _, _, _), do: {:error, :mvp_pull_lookup_failed}

  defp collect_page(pulls, repo, project_id, branch, opts, page, acc) do
    with {:ok, normalized} <- normalize_pulls(pulls, repo, project_id, opts) do
      collected = Enum.reverse(normalized) ++ acc

      if length(pulls) == 100 do
        pull_pages(repo, project_id, branch, opts, page + 1, collected)
      else
        {:ok, Enum.reverse(collected)}
      end
    end
  end

  defp normalize_pulls(pulls, repo, project_id, opts) do
    Enum.reduce_while(pulls, {:ok, []}, fn pull, {:ok, acc} ->
      case normalize_pull(pull, repo, project_id, opts) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  @spec create_pull(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_pull(repo, fields, opts) do
    if gitlab?(opts) do
      body = %{"title" => "Draft: " <> fields["title"], "description" => fields["body"], "source_branch" => fields["head"], "target_branch" => fields["base"]}
      write_pull("POST", repo, "/merge_requests", body, 201, opts)
    else
      GitHub.request("POST", "/repos/#{repo}/pulls", %{}, fields, opts)
    end
  end

  @spec update_pull(String.t(), pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_pull(repo, number, body, opts) do
    if gitlab?(opts) do
      write_pull("PUT", repo, "/merge_requests/#{number}", %{"description" => body}, 200, opts)
    else
      GitHub.request("PATCH", "/repos/#{repo}/pulls/#{number}", %{}, %{"body" => body}, opts)
    end
  end

  defp write_pull(method, repo, path, body, status, opts) do
    with {:ok, _settings} <- scope(repo, opts),
         {:ok, project} <- project_identity(repo, opts),
         {:ok, %{status: ^status, body: pull}} <- GitLab.request(method, project_path(repo) <> path, %{}, body, opts),
         {:ok, normalized} <- normalize_pull(pull, repo, project["id"], opts) do
      {:ok, %{status: status, body: normalized}}
    else
      _ -> {:error, :mvp_publish_uncertain_reconcile_before_retry}
    end
  end

  # Verify project identity using the API, never by substituting the requested path
  # into an unverified MR. Cross-project MRs cannot satisfy this delivery contract.
  defp normalize_pull(pull, repo, project_id, opts) when is_map(pull) do
    with true <- pull["source_project_id"] == project_id and pull["target_project_id"] == project_id,
         true <- is_integer(pull["iid"]) and pull["iid"] > 0,
         true <- pull["web_url"] == pull_url(repo, pull["iid"], opts) do
      {:ok,
       %{
         "number" => pull["iid"],
         "html_url" => pull["web_url"],
         "body" => pull["description"],
         "state" => if(pull["state"] == "opened", do: "open", else: pull["state"]),
         "draft" => pull["draft"] == true or pull["work_in_progress"] == true,
         "head" => %{"repo" => %{"full_name" => repo}, "ref" => pull["source_branch"], "sha" => pull["sha"]},
         "base" => %{"repo" => %{"full_name" => repo}, "ref" => pull["target_branch"]}
       }}
    else
      _ -> {:error, :mvp_pr_identity_mismatch}
    end
  end

  defp normalize_pull(_, _, _, _), do: {:error, :mvp_pr_identity_mismatch}

  @spec pull_url(String.t(), pos_integer(), keyword()) :: String.t()
  def pull_url(repo, number, opts) do
    if gitlab?(opts) do
      case GitLab.connection_settings(Keyword.fetch!(opts, :tracker_settings)) do
        {:ok, settings} -> web_root(settings.api_url) <> "/#{repo}/-/merge_requests/#{number}"
        _ -> ""
      end
    else
      "https://github.com/#{repo}/pull/#{number}"
    end
  end

  @spec receipt_scope(map(), keyword()) :: :ok | {:error, atom()}
  def receipt_scope(data, opts) do
    if gitlab?(opts) or data["tracker_kind"] == "gitlab" do
      with true <- gitlab?(opts) and data["tracker_kind"] == "gitlab",
           {:ok, settings} <- scope(data["repository"], opts),
           true <- data["tracker_api_url"] == settings.api_url do
        :ok
      else
        _ -> {:error, :mvp_tracker_scope_mismatch}
      end
    else
      :ok
    end
  end

  @spec git_env(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def git_env(opts) do
    if gitlab?(opts) do
      gitlab_env(opts)
    else
      provider = provider(opts)
      token = resolve(provider["token"], "GITHUB_TOKEN")

      if is_binary(token) and token != "" and Map.get(provider, "api_url", "https://api.github.com") == "https://api.github.com" do
        {:ok, git_config([{"http.https://github.com/.extraheader", "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)}])}
      else
        {:error, :mvp_requires_github_com_token}
      end
    end
  end

  defp gitlab_env(opts) do
    case GitLab.connection_settings(Keyword.fetch!(opts, :tracker_settings)) do
      {:ok, settings} -> {:ok, git_config(gitlab_config(settings))}
      _ -> {:error, :mvp_requires_gitlab_https_token}
    end
  end

  defp gitlab_config(settings) do
    root = web_root(settings.api_url)

    values = [
      {"http.#{root}/.extraheader", "AUTHORIZATION: basic " <> Base.encode64("oauth2:" <> settings.api_key)},
      {"http.followRedirects", "false"}
    ]

    if settings.ca_file, do: values ++ [{"http.#{root}/.sslCAInfo", settings.ca_file}], else: values
  end

  defp git_config(values) do
    [
      {"GIT_CONFIG_COUNT", Integer.to_string(length(values))}
      | Enum.flat_map(Enum.with_index(values), fn {{key, value}, index} -> [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}] end)
    ]
  end

  defp resolve("$" <> name, fallback), do: System.get_env(name) || System.get_env(fallback)
  defp resolve(nil, fallback), do: System.get_env(fallback)
  defp resolve(value, _), do: value

  defp scope(repo, opts) do
    case GitLab.connection_settings(Keyword.fetch!(opts, :tracker_settings)) do
      {:ok, %{project_path: ^repo} = settings} -> {:ok, settings}
      _ -> {:error, :mvp_tracker_scope_mismatch}
    end
  end

  defp project_identity(repo, opts) do
    case GitLab.request("GET", project_path(repo), %{}, nil, opts) do
      {:ok, %{status: 200, body: %{"path_with_namespace" => ^repo, "id" => id} = project}} when is_integer(id) and id > 0 -> {:ok, project}
      _ -> {:error, :mvp_project_lookup_failed}
    end
  end

  defp project_path(repo), do: "/projects/" <> URI.encode(repo, &URI.char_unreserved?/1)
  defp client(tracker_settings), do: if(Map.get(tracker_settings, :kind) == "gitlab", do: GitLab, else: GitHub)
  defp web_root(api_url), do: String.replace_suffix(api_url, "/api/v4", "")
  defp provider(opts), do: Map.get(Keyword.fetch!(opts, :tracker_settings), :provider, %{})
end
