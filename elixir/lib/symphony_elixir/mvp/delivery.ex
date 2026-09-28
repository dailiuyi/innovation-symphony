defmodule SymphonyElixir.Mvp.Delivery do
  @moduledoc "Controller-owned GitHub draft PR delivery and read-only reconciliation."

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.{Commands, Intake, Receipt}

  @spec repository(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def repository(issue, opts) do
    repo = issue.native_ref["repo"]

    with {:ok, %{status: 200, body: body}} <- Client.request("GET", "/repos/#{repo}", %{}, nil, opts),
         true <- body["full_name"] == repo and is_binary(body["default_branch"]) do
      {:ok, %{repo: repo, base: body["default_branch"], url: "https://github.com/#{repo}.git"}}
    else
      _ -> {:error, :mvp_repository_lookup_failed}
    end
  end

  @spec publish(Path.t(), map(), map(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def publish(workspace, issue, repository, branch, sha, receipt, opts) do
    fields = %{"branch" => branch, "base" => repository.base, "candidate_sha" => sha}
    Receipt.update(receipt, "publish_pending", fields)

    with :ok <- still_ready(issue, opts),
         {:ok, []} <- matching_pulls(repository.repo, branch, opts),
         {:ok, env} <- git_env(opts),
         {:ok, _} <- Commands.git(["push", "--force-with-lease=refs/heads/#{branch}:", repository.url, "#{sha}:refs/heads/#{branch}"], workspace, env: env),
         {:ok, %{status: 201, body: pull}} <-
           Client.request(
             "POST",
             "/repos/#{repository.repo}/pulls",
             %{},
             %{
               "title" => "#{issue.identifier}: #{issue.title}",
               "body" => pr_body(issue, sha),
               "head" => branch,
               "base" => repository.base,
               "draft" => true
             },
             opts
           ),
         :ok <- verify_pull(pull, repository.repo, branch, sha, repository.base) do
      Receipt.update(receipt, "awaiting_human", %{"pull_request" => pull["html_url"]})
      {:ok, pull["html_url"]}
    else
      _ -> {:error, :mvp_publish_uncertain_reconcile_before_retry}
    end
  end

  defp pr_body(issue, sha) do
    """
    #### Context

    Closes ##{issue.id}. The linked issue defines the requested behavior and acceptance criteria.

    #### TL;DR

    *Submit the checked candidate for human review.*

    #### Summary

    - Candidate: `#{sha}`
    - See the diff for implementation details and the issue for scope.

    #### Alternatives

    - Automatic merge and runner upgrade remain disabled; a human decides whether to accept this candidate.

    #### Test Plan

    - [x] Configured machine checks passed for the candidate SHA.
    - [x] A separate read-only reviewer approved the candidate SHA.
    - [ ] Human acceptance, merge and runner upgrade.
    """
  end

  @spec reconcile(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reconcile(receipt, opts \\ []) do
    data = Receipt.read(receipt)

    with true <- data["status"] in ["publish_pending", "awaiting_human"],
         {:ok, [pull]} <- matching_pulls(data["repository"], data["branch"], opts),
         :ok <- verify_pull(pull, data["repository"], data["branch"], data["candidate_sha"], data["base"]) do
      Receipt.update(receipt, "awaiting_human", %{"pull_request" => pull["html_url"]})
      {:ok, pull["html_url"]}
    else
      _ -> {:error, :mvp_no_unique_matching_pr}
    end
  end

  @spec git_env(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def git_env(opts) do
    tracker = Keyword.fetch!(opts, :tracker_settings)
    provider = Map.get(tracker, :provider, %{})
    token = resolve_token(provider["token"])

    if is_binary(token) and token != "" and Map.get(provider, "api_url", "https://api.github.com") == "https://api.github.com" do
      {:ok, [{"GIT_CONFIG_COUNT", "1"}, {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"}, {"GIT_CONFIG_VALUE_0", "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)}]}
    else
      {:error, :mvp_requires_github_com_token}
    end
  end

  defp resolve_token("$" <> name), do: System.get_env(name) || System.get_env("GITHUB_TOKEN")
  defp resolve_token(nil), do: System.get_env("GITHUB_TOKEN")
  defp resolve_token(token), do: token

  defp still_ready(issue, opts) do
    ready_label = Keyword.fetch!(opts, :ready_label)

    case Client.request("GET", "/repos/#{issue.native_ref["repo"]}/issues/#{issue.id}", %{}, nil, opts) do
      {:ok, %{status: 200, body: body}} ->
        if Intake.ready?(body, ready_label), do: :ok, else: {:error, :mvp_no_longer_ready}

      _ ->
        {:error, :mvp_no_longer_ready}
    end
  end

  defp matching_pulls(repo, branch, opts) do
    owner = repo |> String.split("/") |> hd()

    case Client.request("GET", "/repos/#{repo}/pulls", %{"head" => "#{owner}:#{branch}", "state" => "all", "per_page" => 100}, nil, opts) do
      {:ok, %{status: 200, body: pulls}} when is_list(pulls) -> {:ok, pulls}
      _ -> {:error, :mvp_pull_lookup_failed}
    end
  end

  defp verify_pull(pull, repo, branch, sha, base) do
    if get_in(pull, ["head", "repo", "full_name"]) == repo and
         get_in(pull, ["base", "repo", "full_name"]) == repo and
         get_in(pull, ["head", "ref"]) == branch and get_in(pull, ["head", "sha"]) == sha and
         get_in(pull, ["base", "ref"]) == base and is_binary(pull["html_url"]) do
      :ok
    else
      {:error, :mvp_pr_identity_mismatch}
    end
  end
end
