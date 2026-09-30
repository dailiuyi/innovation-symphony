defmodule SymphonyElixir.Mvp.ExternalDraft do
  @moduledoc "Journaled Draft PR delivery without claiming final external acceptance."

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.{Commands, Delivery, ExternalHandoff, Intake, Receipt, Review}

  @spec publish(Path.t(), map(), map(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def publish(workspace, issue, repository, branch, sha, receipt, opts) do
    data = Receipt.read(receipt)

    with true <- data["status"] == "awaiting_external" and data["candidate_sha"] == sha,
         {:ok, record} <- ExternalHandoff.read(%{evidence: receipt <> ".evidence"}, data["external_handoff"]),
         true <- record["source"] == "review" and record["candidate_sha"] == sha and record["workspace"] == workspace,
         true <- record["repository"] == %{"repo" => repository.repo, "base" => repository.base, "url" => repository.url} and record["branch"] == branch,
         {:ok, review, proof} <- review_proof(data, receipt, workspace),
         true <- review == record["source_data"] and Review.external_draft?(review),
         true <- proof["review"]["sha256"] == record["source_digest"] do
      body = external_body(issue, sha, record, proof)
      deliver(workspace, issue, repository, branch, sha, receipt, opts, %{mode: "external", body: body, proof: proof})
    else
      _ -> {:error, :mvp_external_draft_not_eligible}
    end
  end

  @spec approve(Path.t(), map(), map(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def approve(workspace, issue, repository, branch, sha, receipt, opts) do
    data = Receipt.read(receipt)

    case {data["candidate_sha"] == sha, review_proof(data, receipt, workspace)} do
      {true, {:ok, %{"approved" => true}, proof}} ->
        body = """
        #### Context

        Related to ##{issue.id}. The previously pending external conditions have now passed a fresh independent Review.

        #### TL;DR

        *Submit the same Draft PR after all acceptance criteria pass.*

        #### Summary

        - Candidate: `#{sha}`
        - All configured checks and all acceptance criteria passed; the original external handoff remains in the audit history.

        #### Alternatives

        - Keep the existing Draft; a human decides merge and installation.

        #### Test Plan

        - [x] Full configured checks passed for this candidate.
        - [x] A fresh independent reviewer approved all acceptance criteria.
        - [ ] Human acceptance, merge and installation.

        #{proof_body(proof)}
        """

        deliver(workspace, issue, repository, branch, sha, receipt, opts, %{mode: "approved", body: body, proof: proof})

      _ ->
        {:error, :mvp_external_draft_not_eligible}
    end
  end

  defp review_proof(data, receipt, workspace) do
    round = List.last(data["rounds"] || []) || %{}
    path = round["review_path"]
    root = Path.expand(receipt <> ".evidence") <> "/"

    with true <- round["candidate_sha"] == data["candidate_sha"] and is_binary(path),
         true <- String.starts_with?(Path.expand(path), root),
         {:ok, raw} <- read_regular(path),
         {:ok, review} <- Review.parse(raw, 1),
         true <- review == data["review"] and review == round["review"],
         {:ok, ""} <- Commands.git(["status", "--porcelain"], workspace),
         {:ok, head} <- Commands.git(["rev-parse", "HEAD"], workspace),
         true <- head == data["candidate_sha"],
         {:ok, checks} <- check_proofs(round["checks"], Path.dirname(path), receipt, workspace) do
      {:ok, review, %{"review" => %{"path" => path, "sha256" => digest(raw)}, "checks" => checks}}
    else
      _ -> {:error, :proof}
    end
  end

  defp check_proofs(commands, directory, receipt, workspace) when is_list(commands) and commands != [] do
    commands
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {command, index}, {:ok, acc} ->
      path = Path.join(directory, "check-#{index}.json")
      log = Path.join(directory, "check-#{index}.log")

      expected =
        Enum.map(command, &(&1 |> String.replace("{workspace}", workspace) |> String.replace("{baseline}", Path.join(receipt <> ".evidence", "baseline")) |> String.replace("{evidence}", directory)))

      with {:ok, raw} <- read_regular(path),
           {:ok, report} <- Jason.decode(raw),
           true <- report["index"] == index and report["argv"] == expected,
           true <- report["exit_status"] == 0 and report["repairable"] == false and report["log_path"] == log,
           {:ok, bytes} <- read_regular(log) do
        {:cont, {:ok, acc ++ [%{"path" => path, "sha256" => digest(raw), "log_path" => log, "log_sha256" => digest(bytes)}]}}
      else
        _ -> {:halt, {:error, :checks}}
      end
    end)
  end

  defp check_proofs(_, _, _, _), do: {:error, :checks}

  defp external_body(issue, sha, record, proof) do
    conditions =
      Enum.map_join(record["conditions"], "\n\n", fn condition ->
        "- **#{safe_text(condition["acceptance"])}**\n  - Reason: #{safe_text(condition["reason"])}\n  - Required evidence / resolution: #{safe_text(condition["required_evidence"])}\n  - Owner / handoff: #{safe_text(condition["handoff"])}"
      end)

    """
    等待真实外部验收，最终验收尚未通过。

    #### Context

    Related to ##{issue.id}. This Draft preserves the checked implementation for human review while external acceptance remains pending.

    #### TL;DR

    *Deliver the checked candidate as a Draft while real external acceptance remains pending.*

    #### Summary

    - Candidate: `#{sha}`
    - Independent Review: `approved=false`; only explicitly classified external verification conditions remain.
    - Handoff: `#{record["id"]}`. The task remains `awaiting_external`.

    #### Pending external acceptance

    #{conditions}

    #### Alternatives

    - Preserve the Draft and handoff; merging and installation require human decisions.

    #### Test Plan

    - [x] All frozen configured checks passed for this candidate.
    - [ ] Real external evidence, fresh full checks and independent Review of every acceptance criterion.
    - [ ] Human acceptance, merge and installation.

    #{proof_body(proof)}
    """
  end

  defp proof_body(proof) do
    entries = [proof["review"] | proof["checks"]]
    "#### Controller evidence\n\n" <> Enum.map_join(entries, "\n", &"- `#{&1["path"]}` — SHA256 `#{&1["sha256"]}`")
  end

  defp deliver(workspace, issue, repository, branch, sha, receipt, opts, %{mode: mode, body: body, proof: proof}) do
    data = Receipt.read(receipt)
    existing = data["external_delivery"]

    with :ok <- valid_journal(receipt, existing),
         :ok <- previous_delivery(existing, repository, branch, sha),
         {:ok, target} <- target_pull(existing, repository.repo, branch, opts),
         :ok <- ready(issue, opts),
         intent = %{"repository" => repository.repo, "branch" => branch, "base" => repository.base, "candidate_sha" => sha, "mode" => mode, "body" => body, "proof" => proof, "previous_pull" => target},
         {:ok, delivery} <- journal(receipt, intent, data),
         {:ok, pull} <- write_pull(workspace, issue, repository, branch, sha, target, body, opts),
         :ok <- verify_pull(pull, intent) do
      confirm(receipt, delivery, pull)
    else
      {:error, _} = error -> error
    end
  end

  defp previous_delivery(nil, _, _, _), do: :ok

  defp previous_delivery(%{"status" => status, "intent" => old}, repository, branch, sha) when status in ["delivered", "approved"] do
    if old["repository"] == repository.repo and old["branch"] == branch and old["base"] == repository.base and old["candidate_sha"] == sha, do: :ok, else: {:error, :mvp_pr_identity_mismatch}
  end

  defp previous_delivery(_, _, _, _), do: {:error, :mvp_publish_uncertain_reconcile_before_retry}

  defp target_pull(existing, repo, branch, opts) do
    case pulls(repo, branch, opts) do
      {:ok, pulls} -> select_target(existing, pulls)
      error -> error
    end
  end

  defp select_target(nil, []), do: {:ok, nil}

  defp select_target(%{"pull" => old, "intent" => intent}, [pull]) do
    if verify_pull(pull, intent) == :ok and Map.take(pull, ["number", "html_url"]) == old, do: {:ok, old}, else: {:error, :mvp_pr_identity_mismatch}
  end

  defp select_target(_, _), do: {:error, :mvp_no_unique_matching_pr}

  defp journal(receipt, intent, data) do
    root = Path.join(receipt <> ".evidence", "delivery-intents")
    path = Path.join(root, "draft-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json")
    raw = Jason.encode!(intent, pretty: true)

    with :ok <- File.mkdir_p(root), :ok <- File.write(path, raw, [:exclusive, :sync]) do
      delivery = %{"status" => "pending", "intent" => intent, "intent_path" => path, "intent_sha256" => digest(raw)}
      history = (data["external_delivery_history"] || []) ++ List.wrap(data["external_delivery"])
      status = if intent["mode"] == "external", do: "awaiting_external", else: "publish_pending"
      :ok = Receipt.update(receipt, status, %{"external_delivery" => delivery, "external_delivery_history" => history})
      {:ok, delivery}
    end
  end

  defp write_pull(workspace, issue, repository, branch, sha, nil, body, opts) do
    with {:ok, env} <- Delivery.git_env(opts),
         {:ok, _} <- Commands.git(["push", "--force-with-lease=refs/heads/#{branch}:", repository.url, "#{sha}:refs/heads/#{branch}"], workspace, env: env),
         {:ok, %{status: 201, body: pull}} <-
           Client.request(
             "POST",
             "/repos/#{repository.repo}/pulls",
             %{},
             %{"title" => "#{issue.identifier}: #{issue.title}", "body" => body, "head" => branch, "base" => repository.base, "draft" => true},
             opts
           ) do
      {:ok, pull}
    else
      _ -> {:error, :mvp_publish_uncertain_reconcile_before_retry}
    end
  end

  defp write_pull(_workspace, _issue, repository, _branch, _sha, target, body, opts) do
    case Client.request("PATCH", "/repos/#{repository.repo}/pulls/#{target["number"]}", %{}, %{"body" => body}, opts) do
      {:ok, %{status: 200, body: pull}} -> {:ok, pull}
      _ -> {:error, :mvp_publish_uncertain_reconcile_before_retry}
    end
  end

  @spec reconcile(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reconcile(receipt, opts) do
    data = Receipt.read(receipt)
    delivery = data["external_delivery"]

    with %{"intent" => intent} <- delivery,
         :ok <- valid_journal(receipt, delivery),
         true <- intent["candidate_sha"] == data["candidate_sha"] and intent["repository"] == data["repository"] and intent["branch"] == data["branch"],
         {:ok, review, proof} <- review_proof(data, receipt, data["workspace"]),
         true <- proof == intent["proof"] and review_mode?(review, intent["mode"]),
         {:ok, [pull]} <- pulls(intent["repository"], intent["branch"], opts),
         :ok <- verify_pull(pull, intent) do
      confirm(receipt, delivery, pull)
    else
      _ -> {:error, :mvp_no_unique_matching_pr}
    end
  end

  defp review_mode?(%{"approved" => true}, "approved"), do: true
  defp review_mode?(review, "external"), do: Review.external_draft?(review)
  defp review_mode?(_, _), do: false

  defp valid_journal(_receipt, nil), do: :ok

  defp valid_journal(receipt, %{"intent" => intent, "intent_path" => path, "intent_sha256" => sha}) when is_binary(path) do
    with true <- Path.dirname(Path.expand(path)) == Path.expand(Path.join(receipt <> ".evidence", "delivery-intents")),
         {:ok, raw} <- read_regular(path),
         true <- digest(raw) == sha,
         {:ok, ^intent} <- Jason.decode(raw),
         true <- saved_proof_valid?(intent["proof"]) do
      :ok
    else
      _ -> {:error, :mvp_delivery_intent_mismatch}
    end
  end

  defp valid_journal(_, _), do: {:error, :mvp_delivery_intent_mismatch}

  defp saved_proof_valid?(%{"review" => review, "checks" => checks}) do
    files = [review | checks] ++ Enum.map(checks, &%{"path" => &1["log_path"], "sha256" => &1["log_sha256"]})

    Enum.all?(files, fn entry ->
      case read_regular(entry["path"]) do
        {:ok, raw} -> digest(raw) == entry["sha256"]
        _ -> false
      end
    end)
  end

  defp confirm(receipt, delivery, pull) do
    approved = delivery["intent"]["mode"] == "approved"
    status = if approved, do: "awaiting_human", else: "awaiting_external"

    fields = %{
      "pull_request" => pull["html_url"],
      "external_delivery" => Map.merge(delivery, %{"status" => if(approved, do: "approved", else: "delivered"), "pull" => Map.take(pull, ["number", "html_url"])}),
      "reason" => if(approved, do: nil, else: ":mvp_awaiting_external")
    }

    :ok = Receipt.update(receipt, status, fields)
    {:ok, pull["html_url"]}
  end

  defp ready(issue, opts) do
    with {:ok, %{status: 200, body: body}} <- Client.request("GET", "/repos/#{issue.native_ref["repo"]}/issues/#{issue.id}", %{}, nil, opts),
         true <- Intake.ready?(body, Keyword.fetch!(opts, :ready_label)) do
      :ok
    else
      _ -> {:error, :mvp_no_longer_ready}
    end
  end

  defp pulls(repo, branch, opts) do
    owner = repo |> String.split("/") |> hd()

    case Client.request("GET", "/repos/#{repo}/pulls", %{"head" => "#{owner}:#{branch}", "state" => "all", "per_page" => 100}, nil, opts) do
      {:ok, %{status: 200, body: pulls}} when is_list(pulls) -> {:ok, pulls}
      _ -> {:error, :mvp_pull_lookup_failed}
    end
  end

  defp verify_pull(pull, intent) do
    valid = [exact_identity?(pull, intent), open_draft?(pull), pull["body"] == intent["body"], previous_pull?(pull, intent)]

    if Enum.all?(valid) do
      :ok
    else
      {:error, :mvp_pr_identity_mismatch}
    end
  end

  defp exact_identity?(pull, intent) do
    actual = %{
      head_repository: get_in(pull, ["head", "repo", "full_name"]),
      base_repository: get_in(pull, ["base", "repo", "full_name"]),
      branch: get_in(pull, ["head", "ref"]),
      sha: get_in(pull, ["head", "sha"]),
      base: get_in(pull, ["base", "ref"]),
      url: pull["html_url"]
    }

    expected = %{
      head_repository: intent["repository"],
      base_repository: intent["repository"],
      branch: intent["branch"],
      sha: intent["candidate_sha"],
      base: intent["base"],
      url: "https://github.com/#{intent["repository"]}/pull/#{pull["number"]}"
    }

    actual == expected
  end

  defp open_draft?(pull),
    do: pull["draft"] == true and pull["state"] == "open" and is_integer(pull["number"]) and pull["number"] > 0

  defp previous_pull?(pull, %{"previous_pull" => nil}), do: is_map(pull)
  defp previous_pull?(pull, intent), do: Map.take(pull, ["number", "html_url"]) == intent["previous_pull"]

  defp read_regular(path) when is_binary(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path), do: File.read(path)
  end

  defp safe_text(value), do: value |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("#", "&#35;")
  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
