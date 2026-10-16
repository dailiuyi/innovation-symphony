defmodule SymphonyElixir.Mvp.Delivery do
  @moduledoc "Controller-owned GitHub draft PR delivery and read-only reconciliation."

  alias SymphonyElixir.Mvp.{Commands, ExternalDraft, Feedback, Intake, Receipt}
  alias SymphonyElixir.Mvp.Forge

  @spec repository(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def repository(issue, opts), do: Forge.repository(issue, opts)

  @spec publish(Path.t(), map(), map(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def publish(workspace, issue, repository, branch, sha, receipt, opts) do
    if is_map(Receipt.read(receipt)["external_delivery"]) do
      ExternalDraft.approve(workspace, issue, repository, branch, sha, receipt, opts)
    else
      publish_new(workspace, issue, repository, branch, sha, receipt, opts)
    end
  end

  @doc "Publish only a checked candidate whose independent review lacks real external verification."
  @spec publish_external(Path.t(), map(), map(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def publish_external(workspace, issue, repository, branch, sha, receipt, opts),
    do: ExternalDraft.publish(workspace, issue, repository, branch, sha, receipt, opts)

  defp publish_new(workspace, issue, repository, branch, sha, receipt, opts) do
    fields = %{"branch" => branch, "base" => repository.base, "candidate_sha" => sha}
    Receipt.update(receipt, "publish_pending", fields)

    with :ok <- Forge.receipt_scope(Receipt.read(receipt), opts),
         :ok <- still_ready(issue, opts),
         {:ok, []} <- matching_pulls(repository.repo, branch, opts),
         {:ok, env} <- git_env(opts),
         {:ok, _} <- Commands.git(["push", "--force-with-lease=refs/heads/#{branch}:", repository.url, "#{sha}:refs/heads/#{branch}"], workspace, env: env),
         {:ok, %{status: 201, body: pull}} <-
           Forge.create_pull(
             repository.repo,
             %{
               "title" => "#{issue.identifier}: #{issue.title}",
               "body" => pr_body(issue, sha),
               "head" => branch,
               "base" => repository.base,
               "draft" => true
             },
             opts
           ),
         :ok <- verify_pull(pull, repository.repo, branch, sha, repository.base, opts) do
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

    cond do
      is_map(data["external_delivery"]) -> ExternalDraft.reconcile(receipt, opts)
      is_list(data["rounds"]) and data["status"] in ["comment_pending", "blocked"] -> Feedback.reconcile(receipt, opts)
      true -> reconcile_pull(receipt, data, opts)
    end
  end

  defp reconcile_pull(receipt, data, opts) do
    case Forge.receipt_scope(data, opts) do
      :ok -> reconcile_scoped_pull(receipt, data, opts)
      error -> error
    end
  end

  defp reconcile_scoped_pull(receipt, data, opts) do
    with true <- data["status"] in ["publish_pending", "awaiting_human"],
         {:ok, [pull]} <- matching_pulls(data["repository"], data["branch"], opts),
         :ok <- verify_pull(pull, data["repository"], data["branch"], data["candidate_sha"], data["base"], opts) do
      Receipt.update(receipt, "awaiting_human", %{"pull_request" => pull["html_url"]})
      {:ok, pull["html_url"]}
    else
      _ -> {:error, :mvp_no_unique_matching_pr}
    end
  end

  @spec git_env(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def git_env(opts), do: Forge.git_env(opts)

  defp still_ready(issue, opts) do
    ready_label = Keyword.fetch!(opts, :ready_label)

    case Forge.issue(issue, opts) do
      {:ok, %{status: 200, body: body}} ->
        if Intake.ready?(body, ready_label), do: :ok, else: {:error, :mvp_no_longer_ready}

      _ ->
        {:error, :mvp_no_longer_ready}
    end
  end

  defp matching_pulls(repo, branch, opts), do: Forge.pulls(repo, branch, opts)

  defp verify_pull(pull, repo, branch, sha, base, opts) do
    if get_in(pull, ["head", "repo", "full_name"]) == repo and
         get_in(pull, ["base", "repo", "full_name"]) == repo and
         get_in(pull, ["head", "ref"]) == branch and get_in(pull, ["head", "sha"]) == sha and
         get_in(pull, ["base", "ref"]) == base and is_binary(pull["html_url"]) and valid_gitlab_pull?(pull, repo, opts) do
      :ok
    else
      {:error, :mvp_pr_identity_mismatch}
    end
  end

  defp valid_gitlab_pull?(pull, repo, opts) do
    not Forge.gitlab?(opts) or
      (pull["draft"] == true and pull["state"] == "open" and
         is_integer(pull["number"]) and pull["number"] > 0 and
         pull["html_url"] == Forge.pull_url(repo, pull["number"], opts))
  end
end
