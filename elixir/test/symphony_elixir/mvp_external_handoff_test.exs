defmodule SymphonyElixir.Mvp.ExternalHandoffTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.Mvp.External
  alias Mix.Tasks.PrBody.Check, as: PrBodyCheck
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ModelServicesFixture, as: ServiceFixture

  alias SymphonyElixir.Mvp.{
    AutomaticAcceptance,
    Commands,
    Delivery,
    ExecutionSandbox,
    Executor,
    ExternalDraft,
    ExternalHandoff,
    ModelCatalog,
    ModelServices,
    Receipt,
    Recovery,
    Review
  }

  alias SymphonyElixir.Mvp.Config, as: MvpConfig

  @acceptance "The candidate must load the signed company feed"
  @url "https://github.com/owner/repo/pull/42"

  test "the executor automatically continues enabled acceptance through checks and a fresh Review" do
    context = automatic_waiting!("linux", %{}, false)
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_human"
    assert data["review"]["approved"]
    assert data["operator_recheck"] =~ "acceptance-external-"
    assert length(calls(context, :probe)) == 1
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 2
    assert length(writes(context, "POST", "/pulls")) == 1
    assert length(writes(context, "PATCH", "/pulls/42")) == 1
  end

  test "revoked model credentials stop acceptance before invoking the frozen account" do
    context = automatic_waiting!("gpt_coder")
    System.delete_env("GH12_CODER_KEY")
    assert {:error, :automatic_acceptance_probe_failed} = AutomaticAcceptance.prepare(context)
    assert calls(context, :probe) == []
    assert Receipt.read(context.receipt)["external_probe_calls"] == nil
    assert Receipt.read(context.receipt)["external_probe_inflight"] == false
    assert automatic_completion(context)["status"] == "stopped"
  end

  test "automatic fixed evidence rechecks the unchanged candidate and reviews the same draft without another coder" do
    context = automatic_waiting!("linux")
    before = Receipt.read(context.receipt)
    assert {:ok, receipt_digest, auth} = AutomaticAcceptance.prepare(context)
    assert receipt_digest == digest(File.read!(context.receipt))
    [entry] = auth["external_evidence"]
    proof = Jason.decode!(File.read!(entry["path"]))
    assert entry["sha256"] == digest(File.read!(entry["path"]))
    assert proof["binding"]["candidate_sha"] == before["candidate_sha"]
    assert proof["binding"]["execution_sandbox"] == before["execution_sandbox"]
    assert proof["status"] == "passed"
    assert automatic_completion(context)["status"] == "completed"
    assert {:error, :automatic_acceptance_unavailable} = AutomaticAcceptance.prepare(context)
    assert length(calls(context, :probe)) == 1

    assert {:ok, @url} = Executor.resume_external(context, receipt_digest, auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["status"] == "awaiting_human"
    assert after_data["candidate_sha"] == before["candidate_sha"]
    assert after_data["review"]["approved"]
    assert after_data["rework_count"] == before["rework_count"]
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 1
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :formal_check)) == 2
    assert length(writes(context, "POST", "/pulls")) == 1
    assert length(writes(context, "PATCH", "/pulls/42")) == 1
    assert Process.get({context.key, :remote_pull})["draft"]
    assert after_data["external_probe_charged_ms"] == after_data["external_probe_ms"]
    assert hd(after_data["external_review_history"])["source_data"]["approved"] == false
  end

  test "both GPT roles use frozen services and nonce-bound readonly probes, then reserve an independent review" do
    for kind <- ~w(gpt_coder gpt_reviewer) do
      context = automatic_waiting!(kind)
      before = Receipt.read(context.receipt)
      assert {:ok, receipt_digest, auth} = AutomaticAcceptance.prepare(context)
      [entry] = auth["external_evidence"]
      proof = Jason.decode!(File.read!(entry["path"]))
      role = String.replace_prefix(kind, "gpt_", "")
      assert proof["role"] == role
      assert proof["service"] == context.services[role]
      assert proof["response"]["actual_model"] == nil
      assert File.regular?(Path.join(Path.dirname(entry["path"]), "model-0.jsonl"))
      assert Receipt.read(context.receipt)["external_probe_calls"] == 1
      assert {:ok, @url} = Executor.resume_external(context, receipt_digest, auth)
      after_data = Receipt.read(context.receipt)
      assert after_data["recovery"]["agent_attempts"] + after_data["external_probe_calls"] == before["recovery"]["agent_attempts"] + 2
      assert length(calls(context, :coder)) == 1
      assert length(calls(context, :reviewer)) == 2
      assert length(calls(context, :probe)) == 1
    end
  end

  test "probe failures preserve the candidate and usage without coding, review or repeated execution" do
    outcomes = [
      {"linux", :failed},
      {"linux", :missing_export},
      {"gpt_coder", :failed},
      {"gpt_reviewer", :bad_json},
      {"gpt_coder", :wrong_nonce},
      {"gpt_reviewer", :wrong_candidate}
    ]

    for {kind, outcome} <- outcomes do
      context = automatic_waiting!(kind)
      before = Receipt.read(context.receipt)
      Process.put({context.key, :probe_outcome}, outcome)
      assert {:error, :automatic_acceptance_probe_failed} = AutomaticAcceptance.prepare(context)
      after_data = Receipt.read(context.receipt)
      assert after_data["status"] == "awaiting_external"
      assert after_data["candidate_sha"] == before["candidate_sha"]
      assert after_data["recovery"] == before["recovery"]
      assert after_data["external_probe_inflight"] == false
      assert is_integer(after_data["external_probe_ms"])
      assert automatic_completion(context)["status"] == "stopped"
      assert Path.wildcard(Path.join(automatic_directory(context), "probe-*.json")) == []
      assert {:error, :automatic_acceptance_unavailable} = AutomaticAcceptance.prepare(context)
      assert length(calls(context, :probe)) == 1
      assert length(calls(context, :coder)) == 1
      assert length(calls(context, :reviewer)) == 1
      assert writes(context, "PATCH", "/pulls/42") == []
      if kind != "linux", do: assert(after_data["external_probe_calls"] == 1)
    end
  end

  test "runner, candidate, environment and registration changes cannot reuse frozen acceptance" do
    for change <- [:runner, :candidate, :environment, :unregistered, :lock, :disabled, :status, :profiles] do
      context = automatic_waiting!("linux")

      changed =
        case change do
          :runner ->
            File.write!(Path.join(context.settings.sandbox["trusted_root"], "scripts/probe_rootless.py"), "changed trusted probe")
            context

          :candidate ->
            Commands.git!(["commit", "--allow-empty", "-m", "different candidate"], context.workspace)
            context

          :environment ->
            put_in(context.settings.sandbox["image"], "fixture@sha256:" <> String.duplicate("b", 64))

          :unregistered ->
            put_in(context.settings.sandbox["acceptance_profiles"], %{})

          :lock ->
            File.write!(Path.join(context.evidence, "operator-recheck.lock"), "occupied")
            context

          :disabled ->
            put_in(context.settings.recovery.enabled, false)

          :status ->
            Receipt.update(context.receipt, "awaiting_human", %{})
            context

          :profiles ->
            put_in(context.settings.sandbox["acceptance_profiles"], %{@acceptance => "arbitrary command"})
        end

      assert {:error, _} = AutomaticAcceptance.prepare(changed)
      assert calls(context, :probe) == []
      assert length(calls(context, :coder)) == 1
      assert length(calls(context, :reviewer)) == 1
    end
  end

  test "GPT probe budgets include previous probes and leave one call for the independent reviewer" do
    for prior_calls <- [0, 1] do
      context = automatic_waiting!("gpt_coder", %{"max_agent_attempts" => 4})
      if prior_calls > 0, do: Receipt.update(context.receipt, "awaiting_external", %{"external_probe_calls" => prior_calls})

      if prior_calls == 0 do
        assert {:ok, receipt_digest, auth} = AutomaticAcceptance.prepare(context)
        assert {:ok, @url} = Executor.resume_external(context, receipt_digest, auth)
        assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] + Receipt.read(context.receipt)["external_probe_calls"] == 4
      else
        assert {:error, :automatic_acceptance_probe_failed} = AutomaticAcceptance.prepare(context)
        assert calls(context, :probe) == []
        assert Receipt.read(context.receipt)["external_probe_calls"] == prior_calls
        assert automatic_completion(context)["status"] == "stopped"
      end
    end
  end

  test "a repeated external review cannot spend beyond the aggregate model and probe budget" do
    context = automatic_waiting!("gpt_coder", %{"max_agent_attempts" => 4})
    Process.put({context.key, :reviews}, [verification_review()])
    assert {:ok, receipt_digest, auth} = AutomaticAcceptance.prepare(context)
    assert {:error, {:mvp_awaiting_external, _}} = Executor.resume_external(context, receipt_digest, auth)

    waiting = Receipt.read(context.receipt)
    assert waiting["recovery"]["agent_attempts"] == 3
    assert waiting["external_probe_calls"] == 1
    assert waiting["recovery"]["agent_attempts"] + waiting["external_probe_calls"] == context.settings.recovery.max_agent_attempts
    assert waiting["status"] == "awaiting_external"
    raw = File.read!(context.receipt)

    assert {:error, :automatic_acceptance_unavailable} = AutomaticAcceptance.prepare(context)
    refute File.exists?(automatic_directory(context))

    changed_evidence = evidence_file!(context, "signed-feed-v2")
    retry = authorization(context, waiting["external_handoff"], changed_evidence, "exhausted-after-probe")
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_external(context, digest(raw), retry)
    assert File.read!(context.receipt) == raw
    refute File.exists?(Path.join([context.evidence, "operator-rechecks", "exhausted-after-probe"]))
    assert length(calls(context, :probe)) == 1
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :formal_check)) == 2
  end

  test "remaining active time caps probe timeout and consumed time blocks new evidence" do
    context = automatic_waiting!("linux")
    data = Receipt.read(context.receipt)
    {:ok, started, _} = DateTime.from_iso8601(data["recovery"]["started_at"])
    {:ok, waiting, _} = DateTime.from_iso8601(data["external_handoff"]["started_at"])
    active = DateTime.diff(waiting, started, :millisecond) - (data["recovery"]["external_wait_ms"] || 0)
    remaining = 600
    charged = 50
    spent = context.settings.recovery.max_elapsed_ms - active - remaining + charged
    Receipt.update(context.receipt, "awaiting_external", %{"external_probe_ms" => spent, "external_probe_charged_ms" => charged})
    now = DateTime.to_unix(waiting, :millisecond) + spent + 1_000
    context = %{context | opts: Keyword.put(context.opts, :now_ms, fn -> now end)}
    assert {:ok, _, _} = AutomaticAcceptance.prepare(context)
    [probe] = calls(context, :probe)
    assert probe.timeout == 30_000 + remaining

    for state <- [%{"external_probe_ms" => context.settings.recovery.max_elapsed_ms}, %{"external_probe_inflight" => true}, %{"external_probe_calls" => -1}, %{"external_probe_charged_ms" => 1}] do
      waiting_context = automatic_waiting!("linux")
      Receipt.update(waiting_context.receipt, "awaiting_external", state)
      assert {:error, :automatic_acceptance_unavailable} = AutomaticAcceptance.prepare(waiting_context)
      assert calls(waiting_context, :probe) == []
      assert Receipt.read(waiting_context.receipt)["status"] == "awaiting_external"
    end
  end

  test "an evidence write collision stops the job and retains the completed probe charge" do
    context = automatic_waiting!("linux")
    Process.put({context.key, :probe_outcome}, :evidence_collision)
    assert {:error, :automatic_acceptance_stopped} = AutomaticAcceptance.prepare(context)
    assert Receipt.read(context.receipt)["status"] == "awaiting_external"
    assert Receipt.read(context.receipt)["external_probe_inflight"] == false
    assert File.read!(Path.join(automatic_directory(context), "probe-0.json")) == "existing evidence"
    refute File.exists?(Path.join(automatic_directory(context), "completion.json"))
    assert {:error, :automatic_acceptance_unavailable} = AutomaticAcceptance.prepare(context)
    assert length(calls(context, :probe)) == 1
  end

  test "a checked external verification draft stays unaccepted and evidence later updates the same PR" do
    context = context!()
    Process.put({context.key, :reviews}, [verification_review(), approved_review()])
    opts = draft_options(context)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), opts)
    before = Receipt.read(context.receipt)
    assert before["status"] == "awaiting_external"
    assert before["review"]["approved"] == false
    assert before["pull_request"] == @url
    assert before["external_delivery"]["status"] == "delivered"
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1
    [created] = writes(context, "POST", "/pulls")
    assert created["draft"] == true
    assert created["body"] =~ "等待真实外部验收，最终验收尚未通过"
    assert created["body"] =~ "approved=false"
    assert created["body"] =~ before["candidate_sha"]
    refute created["body"] =~ "Closes #"
    refute created["body"] =~ "Fixes #"
    body_path = Path.join(context.root, "draft-body.md")
    File.write!(body_path, created["body"])
    PrBodyCheck.run(["--file", body_path])

    frozen = resume_context(context, settings(), opts)
    assert {:ok, record} = Executor.validate_external_probe(frozen, digest(File.read!(context.receipt)))
    assert record["candidate_sha"] == before["candidate_sha"]
    stale_digest = String.duplicate("0", 64)
    assert {:error, :mvp_external_probe_binding_invalid} = Executor.validate_external_probe(frozen, stale_digest)

    evidence = evidence_file!(context, "real signed feed proof")
    auth = authorization(context, before["external_handoff"], evidence, "draft-acceptance")
    assert {:ok, @url} = Executor.resume_external(resume_context(context, settings(), opts), digest(File.read!(context.receipt)), auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["status"] == "awaiting_human"
    assert after_data["review"]["approved"] == true
    assert after_data["candidate_sha"] == before["candidate_sha"]
    assert length(writes(context, "POST", "/pulls")) == 1
    assert length(writes(context, "PATCH", "/pulls/42")) == 1
    assert after_data["external_delivery_history"] |> hd() |> get_in(["intent", "mode"]) == "external"
    assert hd(after_data["external_review_history"])["source_data"]["approved"] == false
    assert length(calls(context, :coder)) == 1
    assert Process.get({context.key, :remote_pull})["draft"] == true
  end

  test "legacy and unresolved decision reviews park without permission to deliver a draft" do
    for review <- [external_review(), verification_review("decision")] do
      context = context!()
      Process.put({context.key, :reviews}, [review])
      opts = draft_options(context)
      assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), opts)
      assert Receipt.read(context.receipt)["status"] == "awaiting_external"
      assert writes(context, "POST", "/pulls") == []
      refute Review.external_draft?(review)
      assert {:error, :mvp_external_draft_not_eligible} = publish_waiting(context, opts)
    end

    invalid = verification_review("not_applicable")
    assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(invalid), 1)
    refute Review.external_draft?(invalid)
  end

  test "lost draft creation is reconciled only by exact read-only identity, state and body" do
    context = draft_waiting!()
    opts = draft_options(context)
    Process.put({context.key, :lose_write}, true)
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = publish_waiting(context, opts)
    pending = Receipt.read(context.receipt)
    assert pending["status"] == "awaiting_external"
    assert pending["external_delivery"]["status"] == "pending"
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = publish_waiting(context, opts)
    original = Process.get({context.key, :remote_pull})

    for changed <- [
          Map.put(original, "draft", false),
          Map.put(original, "state", "closed"),
          Map.put(original, "body", "edited by a person"),
          put_in(original, ["head", "sha"], String.duplicate("f", 40)),
          Map.put(original, "number", 99)
        ] do
      Process.put({context.key, :remote_pull}, changed)
      assert {:error, :mvp_no_unique_matching_pr} = Delivery.reconcile(context.receipt, opts)
    end

    Process.put({context.key, :remote_pull}, original)
    Process.put({context.key, :duplicate_pulls}, true)
    assert {:error, :mvp_no_unique_matching_pr} = Delivery.reconcile(context.receipt, opts)
    Process.put({context.key, :duplicate_pulls}, false)
    assert {:ok, @url} = Delivery.reconcile(context.receipt, opts)
    assert Receipt.read(context.receipt)["status"] == "awaiting_external"
    assert length(writes(context, "POST", "/pulls")) == 1
    assert writes(context, "PATCH", "/pulls/42") == []
  end

  test "draft publication rejects incomplete checks, changed candidates and corrupted independent evidence" do
    proof_mutations = [:checks_missing, :checks_empty, :check_failed, :check_missing, :review_missing, :wrong_path]
    mutations = proof_mutations ++ [:changed_head, :dirty, :source, :binding]

    for tamper <- mutations do
      context = draft_waiting!()
      data = Receipt.read(context.receipt)
      round = List.last(data["rounds"])

      case tamper do
        :checks_missing ->
          Receipt.update_round(context.receipt, "awaiting_external", %{"checks" => nil})

        :checks_empty ->
          Receipt.update_round(context.receipt, "awaiting_external", %{"checks" => []})

        :check_failed ->
          path = Path.join(Path.dirname(round["review_path"]), "check-1.json")
          report = Jason.decode!(File.read!(path)) |> Map.put("exit_status", 10)
          File.write!(path, Jason.encode!(report))

        :check_missing ->
          File.rm!(Path.join(Path.dirname(round["review_path"]), "check-1.json"))

        :review_missing ->
          File.rm!(round["review_path"])

        :wrong_path ->
          Receipt.update_round(context.receipt, "awaiting_external", %{"review_path" => nil})

        :changed_head ->
          Commands.git!(["commit", "--allow-empty", "-m", "another candidate"], context.workspace)

        :dirty ->
          File.write!(Path.join(context.workspace, "candidate.txt"), "unreviewed")

        :source ->
          update_handoff_record(context, &Map.put(&1, "source", "diagnosis"))

        :binding ->
          update_handoff_record(context, &Map.put(&1, "branch", "other"))
      end

      opts = draft_options(context)
      assert {:error, :mvp_external_draft_not_eligible} = publish_waiting(context, opts)
      assert writes(context, "POST", "/pulls") == []
      assert {:error, :mvp_external_draft_not_eligible} = ExternalDraft.approve(context.workspace, context.issue, context.repository, data["branch"], data["candidate_sha"], context.receipt, opts)
    end
  end

  test "a draft never overwrites an occupied remote branch and cannot ignore readiness or lookup failures" do
    for failure <- [:branch, :ready, :lookup, :credentials, :journal, :pull_exists] do
      context = draft_waiting!()
      data = Receipt.read(context.receipt)
      opts = draft_options(context)

      case failure do
        :branch ->
          Commands.git!(["push", context.repository.url, "#{data["base_sha"]}:refs/heads/#{data["branch"]}"], context.workspace)

        :ready ->
          Process.put({context.key, :not_ready}, true)

        :lookup ->
          Process.put({context.key, :lookup_failure}, true)

        :credentials ->
          :ok

        :pull_exists ->
          Process.put({context.key, :remote_pull}, %{"number" => 99})

        :journal ->
          File.write!(Path.join(context.receipt <> ".evidence", "delivery-intents"), "occupied")
      end

      case failure do
        :credentials ->
          bad_opts = Keyword.put(opts, :tracker_settings, %{provider: %{"repo" => "owner/repo", "token" => "fake", "api_url" => "https://unapproved.example"}})
          assert {:error, _} = publish_waiting(context, bad_opts)

        _ ->
          assert {:error, _} = publish_waiting(context, opts)
      end

      assert writes(context, "POST", "/pulls") == []
      assert Receipt.read(context.receipt)["status"] == "awaiting_external"
    end
  end

  test "draft update uncertainty never duplicates a PR or overwrites a human edit" do
    context = context!()
    Process.put({context.key, :reviews}, [verification_review(), approved_review()])
    opts = draft_options(context)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), opts)
    before = Receipt.read(context.receipt)
    evidence = evidence_file!(context, "real external proof")
    auth = authorization(context, before["external_handoff"], evidence, "lost-draft-update")
    Process.put({context.key, :lose_write}, true)
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = Executor.resume_external(resume_context(context, settings(), opts), digest(File.read!(context.receipt)), auth)
    assert Receipt.read(context.receipt)["status"] == "publish_pending"
    assert {:ok, @url} = Delivery.reconcile(context.receipt, opts)
    accepted = Receipt.read(context.receipt)
    assert accepted["status"] == "awaiting_human"
    Process.put({context.key, :lose_write}, false)
    pull = Process.get({context.key, :remote_pull})
    Process.put({context.key, :remote_pull}, Map.put(pull, "body", "human changes"))
    assert {:error, :mvp_pr_identity_mismatch} = Delivery.publish(context.workspace, context.issue, context.repository, accepted["branch"], accepted["candidate_sha"], context.receipt, opts)
    assert length(writes(context, "POST", "/pulls")) == 1
    assert length(writes(context, "PATCH", "/pulls/42")) == 1
  end

  test "the controller preserves the external stop if the Draft creation response is lost" do
    context = context!()
    Process.put({context.key, :reviews}, [verification_review()])
    Process.put({context.key, :lose_write}, true)
    opts = draft_options(context)
    assert {:error, :mvp_publish_uncertain_reconcile_before_retry} = run(context, settings(), opts)
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_external"
    assert data["review"]["approved"] == false
    assert data["external_handoff"]["status"] == "pending"
    assert length(calls(context, :coder)) == 1
    assert {:ok, @url} = Delivery.reconcile(context.receipt, opts)
    assert Receipt.read(context.receipt)["status"] == "awaiting_external"
  end

  test "the saved delivery intent cannot be changed to reconcile a different PR or candidate" do
    for tamper <- [:file, :shape, :candidate, :path, :dirty, :proof, :proof_missing, :mode] do
      context = draft_waiting!()
      opts = draft_options(context)
      assert {:ok, @url} = publish_waiting(context, opts)
      data = Receipt.read(context.receipt)

      case tamper do
        :file ->
          File.write!(data["external_delivery"]["intent_path"], "{}")

        :shape ->
          Receipt.update(context.receipt, "awaiting_external", %{"external_delivery" => %{}})

        :candidate ->
          Receipt.update(context.receipt, "awaiting_external", %{"candidate_sha" => String.duplicate("e", 40)})

        :path ->
          Receipt.update(context.receipt, "awaiting_external", %{"external_delivery" => Map.put(data["external_delivery"], "intent_path", context.receipt)})

        :dirty ->
          File.write!(Path.join(context.workspace, "candidate.txt"), "not reviewed")

        :proof ->
          File.write!(hd(data["external_delivery"]["intent"]["proof"]["checks"])["log_path"], "modified check log")

        :proof_missing ->
          File.rm!(hd(data["external_delivery"]["intent"]["proof"]["checks"])["log_path"])

        :mode ->
          intent = Map.put(data["external_delivery"]["intent"], "mode", "approved")
          raw = Jason.encode!(intent)
          File.write!(data["external_delivery"]["intent_path"], raw)
          delivery = Map.merge(data["external_delivery"], %{"intent" => intent, "intent_sha256" => digest(raw), "status" => "pending"})
          Receipt.update(context.receipt, "awaiting_external", %{"external_delivery" => delivery})
      end

      assert {:error, :mvp_no_unique_matching_pr} = Delivery.reconcile(context.receipt, opts)
      assert {:error, _} = publish_waiting(context, opts)
      assert length(writes(context, "POST", "/pulls")) == 1
    end
  end

  defp verification_review(kind \\ "verification") do
    update_in(external_review(), ["blockers"], fn blockers -> Enum.map(blockers, &Map.put(&1, "external_kind", kind)) end)
  end

  defp draft_waiting! do
    context = context!()
    Process.put({context.key, :reviews}, [verification_review()])
    opts = options(context) |> Keyword.put(:publish_external, fn _, _, _, _, _, _, _ -> {:ok, @url} end)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), opts)
    context
  end

  defp publish_waiting(context, opts) do
    data = Receipt.read(context.receipt)
    Delivery.publish_external(context.workspace, context.issue, context.repository, data["branch"], data["candidate_sha"], context.receipt, opts)
  end

  defp writes(context, method, suffix) do
    calls(context, :draft_requests) |> Enum.filter(fn {verb, path, _body} -> verb == method and String.ends_with?(path, suffix) end) |> Enum.map(&elem(&1, 2))
  end

  defp draft_options(context) do
    options(context) |> Keyword.put(:publish, &Delivery.publish/7) |> Keyword.put(:ready_label, "ready") |> Keyword.put(:request_fun, draft_request(context))
  end

  defp draft_request(context) do
    fn method, path, _params, body, _settings ->
      record(context, :draft_requests, {method, path, body})

      case {method, path} do
        {"POST", "/repos/owner/repo/issues/42/comments"} ->
          {:ok, %{status: 201, body: %{"id" => 17, "body" => body["body"]}}}

        {"GET", "/repos/owner/repo/issues/42"} ->
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => if(Process.get({context.key, :not_ready}), do: [], else: [%{"name" => "ready"}])}}}

        {"GET", "/repos/owner/repo/pulls"} ->
          draft_pulls(context)

        {"POST", "/repos/owner/repo/pulls"} ->
          draft_create(context, body)

        {"PATCH", "/repos/owner/repo/pulls/42"} ->
          draft_reply(context, Map.put(Process.get({context.key, :remote_pull}), "body", body["body"]), 200)
      end
    end
  end

  defp draft_pulls(context) do
    pulls = List.wrap(Process.get({context.key, :remote_pull}))
    pulls = if Process.get({context.key, :duplicate_pulls}), do: pulls ++ pulls, else: pulls
    if Process.get({context.key, :lookup_failure}), do: {:error, :network}, else: {:ok, %{status: 200, body: pulls}}
  end

  defp draft_create(context, body) do
    data = Receipt.read(context.receipt)

    pull = %{
      "number" => 42,
      "html_url" => @url,
      "state" => "open",
      "draft" => true,
      "head" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => data["branch"], "sha" => data["candidate_sha"]},
      "base" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => "main"},
      "body" => body["body"]
    }

    draft_reply(context, pull, 201)
  end

  defp draft_reply(context, pull, status) do
    Process.put({context.key, :remote_pull}, pull)
    if Process.get({context.key, :lose_write}), do: {:error, :lost_response}, else: {:ok, %{status: status, body: pull}}
  end

  test "external-only review parks the candidate, then hash-verified evidence runs checks and a new independent review" do
    context = context!()
    settings = settings()
    Process.put({context.key, :reviews}, [external_review(), approved_review()])

    assert {:error, {:mvp_awaiting_external, handoff_id}} = run(context, settings, options(context))

    before = Receipt.read(context.receipt)
    handoff = before["external_handoff"]
    record = Jason.decode!(File.read!(handoff["record_path"]))
    assert before["status"] == "awaiting_external"
    assert handoff["id"] == handoff_id
    assert handoff["status"] == "pending"
    assert record["record_path"] == nil
    assert record["candidate_sha"] == before["candidate_sha"]
    assert record["base_sha"] == before["base_sha"]
    assert record["issue_scope"] == before["issue_scope"]
    assert record["conditions"] == external_review()["blockers"]
    assert record["review_path"] == List.last(before["rounds"])["review_path"]
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1
    assert calls(context, :publish) == []

    evidence = evidence_file!(context, "signed-feed-v1")
    resume = resume_context(context, settings, options(context))
    auth = authorization(context, handoff, evidence, "resume-external-1")

    assert {:ok, @url} = Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)

    after_data = Receipt.read(context.receipt)
    operation = Path.join([context.receipt <> ".evidence", "operator-rechecks", "resume-external-1"])
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_data["recovery"]["external_wait_ms"] >= 0
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 1
    assert File.regular?(Path.join(operation, "check-1.log"))
    assert File.regular?(Path.join(operation, "external-evidence/evidence-1.bin"))
    assert File.read!(Path.join(operation, "external-evidence/evidence-1.bin")) == "signed-feed-v1"
    assert Enum.at(calls(context, :reviewer), 1).prompt =~ "untrusted evidence"
    assert Enum.at(calls(context, :reviewer), 1).prompt =~ "external-evidence/evidence-1.bin"
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :publish)) == 1
  end

  test "a repeated handoff rejects an identical evidence snapshot but accepts changed evidence on the same candidate" do
    context = context!()
    settings = settings()
    Process.put({context.key, :reviews}, [external_review(), external_review(), external_review(), approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings, options(context))

    evidence = evidence_file!(context, "signed-feed-v1")
    first_handoff = Receipt.read(context.receipt)["external_handoff"]
    first_resume = resume_context(context, settings, options(context))
    first_auth = authorization(context, first_handoff, evidence, "resume-external-1")

    assert {:error, {:mvp_awaiting_external, _}} =
             Executor.resume_external(first_resume, digest(File.read!(context.receipt)), first_auth)

    waiting = Receipt.read(context.receipt)
    assert waiting["status"] == "awaiting_external"
    second_handoff = waiting["external_handoff"]
    second_resume = resume_context(context, settings, options(context))
    repeated_auth = authorization(context, second_handoff, evidence, "resume-external-2")

    assert {:error, :mvp_external_evidence_invalid} =
             Executor.resume_external(second_resume, digest(File.read!(context.receipt)), repeated_auth)

    assert length(calls(context, :reviewer)) == 2
    assert waiting == Receipt.read(context.receipt)

    changed_evidence = evidence_file!(context, "signed-feed-v2")
    fresh_auth = authorization(context, second_handoff, changed_evidence, "resume-external-3")
    fresh_resume = resume_context(context, settings, options(context))

    assert {:error, {:mvp_awaiting_external, _}} =
             Executor.resume_external(fresh_resume, digest(File.read!(context.receipt)), fresh_auth)

    assert length(calls(context, :reviewer)) == 3
    third_handoff = Receipt.read(context.receipt)["external_handoff"]
    third_proof = evidence_file!(context, "signed-feed-v3")
    third_auth = authorization(context, third_handoff, third_proof, "resume-external-4") |> Map.delete("handoff_id")
    third_resume = resume_context(context, settings, options(context))

    assert {:ok, @url} = Executor.resume_external(third_resume, digest(File.read!(context.receipt)), third_auth)
    assert length(calls(context, :reviewer)) == 4
    assert length(Receipt.read(context.receipt)["external_evidence_history"]) == 3
  end

  test "a reparked handoff retains and verifies the original operator review audit" do
    context = context!()
    add_ignored_cache!(context, 16 * 1_024 * 1_024)
    Process.put({context.key, :reviews}, [external_review(), external_review(), approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    first_handoff = Receipt.read(context.receipt)["external_handoff"]
    first_proof = evidence_file!(context, "signed-feed-v1")
    first_auth = authorization(context, first_handoff, first_proof, "source-review-a") |> Map.delete("handoff_id")
    first_resume = resume_context(context, settings(), options(context))

    assert {:error, {:mvp_awaiting_external, _}} =
             Executor.resume_external(first_resume, digest(File.read!(context.receipt)), first_auth)

    after_review = Receipt.read(context.receipt)
    review_handoff = after_review["external_handoff"]
    review_record = Jason.decode!(File.read!(review_handoff["record_path"]))
    source_audit = review_record["source_review_audit"]
    assert source_audit["operation_id"] == first_auth["id"]
    assert source_audit["parent_handoff_id"] == first_handoff["id"]
    assert review_record["review_path"] == Path.join([context.receipt <> ".evidence", "operator-rechecks", first_auth["id"], "review.json"])

    second_proof = evidence_file!(context, "signed-feed-v2")
    second_auth = authorization(context, review_handoff, second_proof, "source-review-b") |> Map.delete("handoff_id")
    second_operation = Path.join([context.receipt <> ".evidence", "operator-rechecks", second_auth["id"]])
    second_auth_path = Path.join(second_operation, "authorization.json")
    external_evidence_dir = Path.join(second_operation, "external-evidence")

    watcher =
      Task.async(fn ->
        wait_for_file!(second_auth_path)
        File.mkdir!(external_evidence_dir)
      end)

    second_resume = resume_context(context, settings(), options(context))

    assert {:error, :mvp_external_evidence_invalid} =
             Executor.resume_external(second_resume, digest(File.read!(context.receipt)), second_auth)

    assert :ok = Task.await(watcher, 10_000)
    after_repark = Receipt.read(context.receipt)
    retried_handoff = after_repark["external_handoff"]
    retried_record = Jason.decode!(File.read!(retried_handoff["record_path"]))
    assert retried_record["source_review_audit"] == source_audit
    assert retried_record["source_review_handoff_id"] == review_handoff["id"]
    assert retried_record["predecessor_handoff"]["id"] == review_handoff["id"]
    assert retried_record["review_path"] == review_record["review_path"]
    assert after_repark["operator_recheck"] == second_auth["id"]

    third_proof = evidence_file!(context, "signed-feed-v3")
    third_auth = authorization(context, retried_handoff, third_proof, "source-review-c") |> Map.delete("handoff_id")
    third_resume = resume_context(context, settings(), options(context))

    assert {:ok, @url} =
             Executor.resume_external(third_resume, digest(File.read!(context.receipt)), third_auth)

    assert length(calls(context, :reviewer)) == 3
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :publish)) == 1
  end

  test "malformed external review source audit fields fail before a second recheck" do
    for tamper <- [:handoff_predecessor, :operation_predecessor, :evidence_history] do
      context = context!()
      Process.put({context.key, :reviews}, [external_review(), external_review(), approved_review()])
      assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

      first_handoff = Receipt.read(context.receipt)["external_handoff"]
      first_auth = authorization(context, first_handoff, evidence_file!(context, "signed-feed-v1"), "audit-source-a")
      first_resume = resume_context(context, settings(), options(context))

      assert {:error, {:mvp_awaiting_external, _}} =
               Executor.resume_external(first_resume, digest(File.read!(context.receipt)), Map.delete(first_auth, "handoff_id"))

      review_handoff = Receipt.read(context.receipt)["external_handoff"]

      case tamper do
        :handoff_predecessor ->
          update_handoff_record(context, &Map.put(&1, "predecessor_handoff", "forged-pointer"))

        :operation_predecessor ->
          operation_directory = Path.join([context.receipt <> ".evidence", "operator-rechecks", first_auth["id"]])
          authorization_path = Path.join(operation_directory, "authorization.json")
          source_authorization = File.read!(authorization_path) |> Jason.decode!() |> Map.put("predecessor", %{"invalid" => true})
          authorization_raw = Jason.encode!(source_authorization, pretty: true)
          File.write!(authorization_path, authorization_raw)

          update_handoff_record(context, fn record ->
            Map.update!(record, "source_review_audit", &Map.put(&1, "authorization_sha256", digest(authorization_raw)))
          end)

        :evidence_history ->
          malformed_history = [["not an evidence record"]]
          update_handoff_record(context, &Map.put(&1, "prior_evidence_history", malformed_history))
          Receipt.update(context.receipt, "awaiting_external", %{"external_evidence_history" => malformed_history})
      end

      before = File.read!(context.receipt)
      current_handoff = Receipt.read(context.receipt)["external_handoff"]
      evidence = evidence_file!(context, "signed-feed-v2")
      authorization = authorization(context, current_handoff, evidence, "audit-source-b") |> Map.delete("handoff_id")
      resume = resume_context(context, settings(), options(context))

      assert {:error, :mvp_external_handoff_mismatch} =
               Executor.resume_external(resume, digest(before), authorization)

      assert File.read!(context.receipt) == before
      refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks", authorization["id"]]))
      assert length(calls(context, :reviewer)) == 2
      assert review_handoff["id"] == current_handoff["id"]
    end
  end

  test "waiting cannot revive an exhausted model-attempt budget or a legacy blocked receipt" do
    context = context!()
    settings = settings(%{"max_agent_attempts" => 2})
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings, options(context))

    evidence = evidence_file!(context, "signed-feed-v1")
    handoff = Receipt.read(context.receipt)["external_handoff"]
    resume = resume_context(context, settings, options(context))
    auth = authorization(context, handoff, evidence, "exhausted-resume")

    for attempts <- [2, -1] do
      recovery = Receipt.read(context.receipt)["recovery"] |> Map.put("agent_attempts", attempts)
      :ok = Receipt.update(context.receipt, "awaiting_external", %{"recovery" => recovery})

      expected = if attempts == 2, do: :mvp_recovery_resource_exhausted, else: :mvp_external_handoff_mismatch

      assert {:error, ^expected} =
               Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)
    end

    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
    assert length(calls(context, :reviewer)) == 1

    blocked = Receipt.read(context.receipt)
    Receipt.update(context.receipt, "blocked", %{"reason" => ":mvp_check_failed"})
    blocked_context = resume_context(context, settings, options(context))

    assert {:error, :mvp_resume_binding_mismatch} =
             Executor.resume_external(blocked_context, digest(File.read!(context.receipt)), auth)

    assert blocked["external_handoff"]["status"] == "pending"
  end

  test "a waiting receipt cannot reset policy, attempt history or recorded usage", do: reject_changed_recovery()

  defp reject_changed_recovery do
    context = context!()
    config = settings()
    Process.put({context.key, :reviews}, [external_review()])
    opts = options(context)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)
    original = File.read!(context.receipt)
    waiting = Jason.decode!(original)
    resume = resume_context(context, config, opts)
    auth = authorization(context, waiting["external_handoff"], evidence_file!(context, "signed proof"), "tampered-budget")

    changes = [
      %{"recovery" => put_in(waiting["recovery"], ["policy", "max_elapsed_ms"], 1)},
      %{"recovery" => Map.put(waiting["recovery"], "agent_attempts", 0)},
      %{"recovery" => Map.update!(waiting["recovery"], "events", &(&1 ++ [%{"attempt" => 0}]))},
      %{"usage" => %{}},
      %{"rework_count" => 20}
    ]

    for change <- changes do
      File.write!(context.receipt, original)
      Receipt.update(context.receipt, "awaiting_external", change)
      changed = File.read!(context.receipt)
      assert {:error, reason} = Executor.resume_external(resume, digest(changed), auth)
      assert reason in [:mvp_external_handoff_mismatch, :mvp_resume_binding_mismatch]
      assert File.read!(context.receipt) == changed
    end

    assert length(calls(context, :reviewer)) == 1
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
  end

  test "disabled recovery, invalid source evidence and negative wait fail closed" do
    disabled = context!()
    enabled_settings = settings()
    Process.put({disabled.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(disabled, enabled_settings, options(disabled))
    disabled_before = File.read!(disabled.receipt)
    disabled_settings = settings(%{"enabled" => false})
    disabled_resume = resume_context(disabled, disabled_settings, options(disabled))

    assert {:error, :mvp_recovery_not_enabled} =
             Executor.resume_external(disabled_resume, digest(disabled_before), %{})

    assert File.read!(disabled.receipt) == disabled_before

    invalid_source = context!()
    Process.put({invalid_source.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(invalid_source, enabled_settings, options(invalid_source))
    invalid_source_before = File.read!(invalid_source.receipt)
    update_handoff_record(invalid_source, &Map.put(&1, "source_data", %{}))
    invalid_source_raw = File.read!(invalid_source.receipt)
    source_resume = resume_context(invalid_source, enabled_settings, options(invalid_source))
    evidence = evidence_file!(invalid_source, "signed-feed-v1")
    source_auth = authorization(invalid_source, Receipt.read(invalid_source.receipt)["external_handoff"], evidence, "invalid-source")

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(source_resume, digest(invalid_source_raw), source_auth)

    refute invalid_source_raw == invalid_source_before
    assert File.read!(invalid_source.receipt) == invalid_source_raw
    refute File.exists?(Path.join([invalid_source.receipt <> ".evidence", "operator-rechecks"]))

    invalid_time = context!()
    Process.put({invalid_time.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(invalid_time, enabled_settings, options(invalid_time))
    update_handoff_record(invalid_time, &Map.put(&1, "started_at", "not-an-iso8601-time"))
    invalid_time_raw = File.read!(invalid_time.receipt)
    invalid_time_handoff = Receipt.read(invalid_time.receipt)["external_handoff"]

    invalid_time_auth =
      authorization(
        invalid_time,
        invalid_time_handoff,
        evidence_file!(invalid_time, "signed-feed-v1"),
        "invalid-handoff-time"
      )

    invalid_time_resume = resume_context(invalid_time, enabled_settings, options(invalid_time))

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(invalid_time_resume, digest(invalid_time_raw), invalid_time_auth)

    assert File.read!(invalid_time.receipt) == invalid_time_raw

    negative_wait = context!()
    Process.put({negative_wait.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(negative_wait, enabled_settings, options(negative_wait))
    handoff = Receipt.read(negative_wait.receipt)["external_handoff"]
    {:ok, started_at, _} = DateTime.from_iso8601(handoff["started_at"])
    before = File.read!(negative_wait.receipt)
    wait_options = Keyword.put(options(negative_wait), :now_ms, fn -> DateTime.to_unix(started_at, :millisecond) - 1 end)
    wait_resume = resume_context(negative_wait, enabled_settings, wait_options)
    wait_evidence = evidence_file!(negative_wait, "signed-feed-v1")
    wait_auth = authorization(negative_wait, handoff, wait_evidence, "negative-wait")

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(wait_resume, digest(before), wait_auth)

    assert File.read!(negative_wait.receipt) == before
    refute File.exists?(Path.join([negative_wait.receipt <> ".evidence", "operator-rechecks"]))

    invalid_clock_options = Keyword.put(options(negative_wait), :now_ms, fn -> :not_a_timestamp end)
    invalid_clock_resume = resume_context(negative_wait, enabled_settings, invalid_clock_options)

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(invalid_clock_resume, digest(before), wait_auth)

    assert File.read!(negative_wait.receipt) == before
  end

  test "mutating immutable handoff bytes is rejected before an operator recheck starts" do
    context = context!()
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    receipt_before = File.read!(context.receipt)
    handoff = Receipt.read(context.receipt)["external_handoff"]
    raw = File.read!(handoff["record_path"])
    record = Jason.decode!(raw) |> Map.put("source_raw", "tampered immutable source")
    File.write!(handoff["record_path"], Jason.encode!(record, pretty: true))
    evidence = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, handoff, evidence, "tampered-immutable-source")
    resume = resume_context(context, settings(), options(context))

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(resume, digest(receipt_before), auth)

    assert File.read!(context.receipt) == receipt_before
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
    assert length(calls(context, :reviewer)) == 1
  end

  test "malformed recovery attempt counts are rejected before any external evidence is copied" do
    context = context!()
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    recovery = Receipt.read(context.receipt)["recovery"] |> Map.put("agent_attempts", "not-an-integer")
    :ok = Receipt.update(context.receipt, "awaiting_external", %{"recovery" => recovery})
    update_handoff_record(context, &Map.put(&1, "recovery_state", recovery))

    handoff_raw = File.read!(context.receipt)
    handoff = Receipt.read(context.receipt)["external_handoff"]
    evidence = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, handoff, evidence, "invalid-attempt-count")
    resume = resume_context(context, settings(), options(context))

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_external(resume, digest(handoff_raw), auth)

    assert File.read!(context.receipt) == handoff_raw
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
    assert length(calls(context, :reviewer)) == 1
  end

  test "post-lock changes to the frozen workspace are parked for an explicit retry" do
    context = context!()
    cache = add_ignored_cache!(context, 16 * 1_024 * 1_024)
    replacement = Path.join(context.root, "replacement-cache.bin")
    File.write!(replacement, :binary.copy("b", 16 * 1_024 * 1_024))
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    handoff = Receipt.read(context.receipt)["external_handoff"]
    evidence = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, handoff, evidence, "postlock-workspace-change")
    authorization_path = Path.join([context.receipt <> ".evidence", "operator-rechecks", auth["id"], "authorization.json"])

    watcher =
      Task.async(fn ->
        wait_for_file!(authorization_path)
        File.write!(cache, File.read!(replacement))
        :ok
      end)

    resume = resume_context(context, settings(), options(context))

    assert {:error, :mvp_external_workspace_changed} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)

    assert :ok = Task.await(watcher, 10_000)
    waiting = Receipt.read(context.receipt)
    assert waiting["status"] == "awaiting_external"
    assert waiting["reason"] == ":mvp_awaiting_external"
    assert waiting["operator_recheck"] == auth["id"]
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :coder)) == 1
  end

  test "post-lock external proof changes park without replacing a concurrent receipt update" do
    context = context!()
    add_ignored_cache!(context, 16 * 1_024 * 1_024)
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    handoff = Receipt.read(context.receipt)["external_handoff"]
    source_proof = evidence_file!(context, :binary.copy("a", 10 * 1_024 * 1_024))
    auth = authorization(context, handoff, source_proof, "postlock-proof-change")
    operation_dir = Path.join([context.receipt <> ".evidence", "operator-rechecks", auth["id"]])
    external_evidence_dir = Path.join(operation_dir, "external-evidence")
    authorization_path = Path.join(operation_dir, "authorization.json")

    watcher =
      Task.async(fn ->
        wait_for_file!(authorization_path)
        File.mkdir!(external_evidence_dir)
        Receipt.update(context.receipt, "awaiting_external", %{"reason" => ":concurrent_receipt_update"})
      end)

    resume = resume_context(context, settings(), options(context))
    before = File.read!(context.receipt)

    assert {:error, :mvp_external_evidence_invalid} =
             Executor.resume_external(resume, digest(before), auth)

    assert :ok = Task.await(watcher, 10_000)
    after_race = Receipt.read(context.receipt)
    assert after_race["status"] == "awaiting_external"
    assert after_race["reason"] == ":concurrent_receipt_update"
    assert is_nil(after_race["operator_recheck"])
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :coder)) == 1
    assert File.regular?(Path.join(operation_dir, "completion.json"))
  end

  test "failed locked work excludes active attempt time from the next external wait credit" do
    context = context!()
    add_ignored_cache!(context, 16 * 1_024 * 1_024)
    Process.put({context.key, :reviews}, [external_review(), approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    before = Receipt.read(context.receipt)
    first_handoff = before["external_handoff"]
    first_record = Jason.decode!(File.read!(first_handoff["record_path"]))
    {:ok, handoff_start, _} = DateTime.from_iso8601(first_handoff["started_at"])
    handoff_start_ms = DateTime.to_unix(handoff_start, :millisecond)
    first_wait_ms = 5_000
    failed_attempt_ms = 2_000
    clock = :atomics.new(1, signed: true)
    attempt_start_ms = handoff_start_ms + first_wait_ms
    attempt_end_ms = attempt_start_ms + failed_attempt_ms
    :atomics.put(clock, 1, attempt_start_ms)
    opts = Keyword.put(options(context), :now_ms, fn -> :atomics.get(clock, 1) end)
    source_proof = evidence_file!(context, :binary.copy("a", 10 * 1_024 * 1_024))
    first_auth = authorization(context, first_handoff, source_proof, "budgeted-failed-attempt")
    first_operation = Path.join([context.receipt <> ".evidence", "operator-rechecks", first_auth["id"]])
    external_evidence_dir = Path.join(first_operation, "external-evidence")
    authorization_path = Path.join(first_operation, "authorization.json")

    watcher =
      Task.async(fn ->
        wait_for_file!(authorization_path)
        File.mkdir!(external_evidence_dir)
        :atomics.put(clock, 1, attempt_end_ms)
      end)

    first_resume = resume_context(context, settings(), opts)

    assert {:error, :mvp_external_evidence_invalid} =
             Executor.resume_external(first_resume, digest(File.read!(context.receipt)), first_auth)

    assert :ok = Task.await(watcher, 10_000)
    after_failure = Receipt.read(context.receipt)
    assert after_failure["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_failure["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"]
    assert after_failure["recovery"]["events"] == before["recovery"]["events"]
    assert after_failure["usage"] == before["usage"]
    assert after_failure["rework_count"] == before["rework_count"]
    assert after_failure["recovery"]["external_wait_ms"] == first_wait_ms

    second_handoff = after_failure["external_handoff"]
    second_record = Jason.decode!(File.read!(second_handoff["record_path"]))
    {:ok, second_start, _} = DateTime.from_iso8601(second_handoff["started_at"])
    assert DateTime.to_unix(second_start, :millisecond) == attempt_end_ms
    assert second_record["workspace_sha256"] == first_record["workspace_sha256"]
    assert second_record["candidate_sha"] == first_record["candidate_sha"]
    assert second_record["conditions"] == first_record["conditions"]
    assert second_record["source_raw"] == first_record["source_raw"]
    assert second_record["source_digest"] == first_record["source_digest"]
    assert second_record["recovery_state"] == after_failure["recovery"]
    assert second_record["external_wait_ms"] == first_wait_ms
    second_resume_wait_ms = 3_000
    :atomics.put(clock, 1, attempt_end_ms + second_resume_wait_ms)
    second_auth = authorization(context, second_handoff, source_proof, "budgeted-successful-retry")
    second_resume = resume_context(context, settings(), opts)

    assert {:ok, @url} =
             Executor.resume_external(second_resume, digest(File.read!(context.receipt)), second_auth)

    final = Receipt.read(context.receipt)
    assert final["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert final["recovery"]["external_wait_ms"] == first_wait_ms + second_resume_wait_ms
  end

  test "an invalid failed-attempt end clock blocks instead of leaving a stale pending handoff" do
    context = context!()
    add_ignored_cache!(context, 16 * 1_024 * 1_024)
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    handoff = Receipt.read(context.receipt)["external_handoff"]
    {:ok, handoff_start, _} = DateTime.from_iso8601(handoff["started_at"])
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, DateTime.to_unix(handoff_start, :millisecond) + 1_000)
    opts = Keyword.put(options(context), :now_ms, fn -> :atomics.get(clock, 1) end)
    proof = evidence_file!(context, :binary.copy("a", 10 * 1_024 * 1_024))
    auth = authorization(context, handoff, proof, "invalid-repark-clock")
    authorization_path = Path.join([context.receipt <> ".evidence", "operator-rechecks", auth["id"], "authorization.json"])
    external_evidence_dir = Path.join([context.receipt <> ".evidence", "operator-rechecks", auth["id"], "external-evidence"])

    watcher =
      Task.async(fn ->
        wait_for_file!(authorization_path)
        File.mkdir!(external_evidence_dir)
        :atomics.put(clock, 1, 9_000_000_000_000_000_000)
      end)

    resume = resume_context(context, settings(), opts)

    assert {:error, :mvp_external_evidence_invalid} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)

    assert :ok = Task.await(watcher, 10_000)
    blocked = Receipt.read(context.receipt)
    assert blocked["status"] == "blocked"
    assert blocked["reason"] == ":mvp_external_repark_failed"
    assert blocked["operator_recheck"] == auth["id"]
    assert blocked["recovery"]["external_wait_ms"] == 0
  end

  test "a failed immutable repark write blocks the prepared receipt" do
    context = context!()
    cache = add_ignored_cache!(context, 16 * 1_024 * 1_024)
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))

    handoff = Receipt.read(context.receipt)["external_handoff"]
    proof = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, handoff, proof, "failed-repark-write")
    operation_dir = Path.join([context.receipt <> ".evidence", "operator-rechecks", auth["id"]])
    authorization_path = Path.join(operation_dir, "authorization.json")
    handoff_root = Path.join(context.receipt <> ".evidence", "external-handoffs")
    preserved_handoff_root = handoff_root <> "-preserved"
    calls = :atomics.new(1, signed: true)
    clock_start = System.system_time(:millisecond)

    now_ms = fn ->
      call = :atomics.add_get(calls, 1, 1)

      if call == 3 do
        File.rename!(handoff_root, preserved_handoff_root)
        File.write!(handoff_root, "block repark persistence")
      end

      clock_start + call * 1_000
    end

    watcher =
      Task.async(fn ->
        wait_for_file!(authorization_path)
        File.write!(cache, "changed after lock")
      end)

    opts = Keyword.put(options(context), :now_ms, now_ms)
    resume = resume_context(context, settings(), opts)

    assert {:error, :mvp_external_workspace_changed} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)

    assert :ok = Task.await(watcher, 10_000)
    blocked = Receipt.read(context.receipt)
    assert blocked["status"] == "blocked"
    assert blocked["reason"] == ":mvp_external_repark_failed"
    assert blocked["operator_recheck"] == auth["id"]
    assert blocked["recovery"]["external_wait_ms"] > 0
    assert File.dir?(preserved_handoff_root)
    assert File.regular?(handoff_root)
  end

  test "a nil handoff start time is rejected before opening an operator recheck" do
    context = context!()
    Process.put({context.key, :reviews}, [external_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), options(context))
    update_handoff_record(context, &Map.put(&1, "started_at", nil))

    before = File.read!(context.receipt)
    handoff = Receipt.read(context.receipt)["external_handoff"]
    proof = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, handoff, proof, "nil-handoff-start")
    resume = resume_context(context, settings(), options(context))

    assert {:error, :mvp_external_handoff_mismatch} =
             Executor.resume_external(resume, digest(before), auth)

    assert File.read!(context.receipt) == before
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
  end

  test "invalid handoff clock type and range preserve the posted review without a handoff" do
    for {invalid_now, expected} <- [
          {:not_a_timestamp, :mvp_external_handoff_invalid},
          {9_999_999_999_999_999_999, :invalid_unix_time}
        ] do
      context = context!()
      Process.put({context.key, :reviews}, [external_review()])
      original_request = comment_request()

      request = fn method, path, params, body, opts ->
        result = original_request.(method, path, params, body, opts)
        if method == "POST", do: Process.put({context.key, :invalid_handoff_clock}, true)
        result
      end

      opts =
        options(context)
        |> Keyword.put(:request_fun, request)
        |> Keyword.put(:now_ms, fn ->
          if Process.get({context.key, :invalid_handoff_clock}, false),
            do: invalid_now,
            else: System.system_time(:millisecond)
        end)

      assert {:error, ^expected} = run(context, settings(), opts)
      data = Receipt.read(context.receipt)
      assert data["status"] == "blocked"
      assert is_map(List.last(data["rounds"])["comment"])
      assert is_nil(data["external_handoff"])
      assert calls(context, :publish) == []
    end
  end

  test "damaged saved external evidence cannot enter audited recovery" do
    context = context!()
    counter = Path.join(context.root, "tamper-check-count")
    script = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); sys.exit(10 if n==2 else 0)"
    config = %{settings(%{"max_elapsed_ms" => 30_000}) | checks: [["python3", "-c", script, counter]]}
    Process.put({context.key, :reviews}, [external_review()])
    opts = timed_options(context)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)

    waiting = Receipt.read(context.receipt)
    evidence = evidence_file!(context, "signed-feed-v1")
    auth = authorization(context, waiting["external_handoff"], evidence, "damaged-proof")
    Process.put({context.key, :expire_on_check}, true)
    resume = resume_context(context, config, opts)

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), auth)

    blocked = Receipt.read(context.receipt)
    [saved_proof] = List.last(blocked["external_evidence_history"])
    File.write!(saved_proof["path"], "tampered proof")
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    recovery_auth = recovery_authorization(context, "reject-damaged-proof", workspace_sha, "damaged-proof")
    recovery_resume = resume_context(context, config, opts)
    blocked_raw = File.read!(context.receipt)

    assert {:error, :mvp_recovery_evidence_mismatch} =
             Executor.resume_recovery(recovery_resume, digest(blocked_raw), recovery_auth)

    assert File.read!(context.receipt) == blocked_raw
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1
    assert File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks", "damaged-proof", "completion.json"]))
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks", "reject-damaged-proof"]))
  end

  test "handoff persistence failure blocks without inventing a pending handoff" do
    context = context!()
    Process.put({context.key, :reviews}, [external_review()])
    original_request = comment_request()

    request = fn method, path, params, body, opts ->
      if method == "POST" do
        collision = Path.join([context.receipt <> ".evidence", "external-handoffs"])
        File.rm_rf!(collision)
        File.write!(collision, "cannot create handoff directory")
      end

      original_request.(method, path, params, body, opts)
    end

    opts = Keyword.put(options(context), :request_fun, request)

    assert {:error, :mvp_external_handoff_invalid} = run(context, settings(), opts)

    data = Receipt.read(context.receipt)
    assert data["status"] == "blocked"
    assert is_nil(data["external_handoff"])
    assert is_map(List.last(data["rounds"])["comment"])
    assert length(calls(context, :reviewer)) == 1
    assert calls(context, :publish) == []
  end

  test "diagnosis cannot use await_external to set aside a known repairable code failure" do
    context = context!()
    settings = settings(%{"diagnose_every" => 1})
    settings = %{settings | checks: [["python3", "-c", "import sys; sys.exit(10)"]]}
    Process.put({context.key, :diagnosis_action}, "await_external")
    opts = options(context)

    assert {:error, :mvp_invalid_diagnosis} = run(context, settings, opts)
    data = Receipt.read(context.receipt)
    assert data["status"] == "blocked"
    assert is_nil(data["external_handoff"])
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :diagnosis)) == 1
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
  end

  test "one operator evidence file can cover multiple blockers for the same acceptance" do
    context = context!()
    evidence = evidence_file!(context, "signed-feed-and-key-proof")

    conditions = [
      hd(external_review()["blockers"]),
      %{
        "acceptance" => @acceptance,
        "kind" => "external_condition",
        "reason" => "The key fingerprint also needs confirmation.",
        "required_evidence" => "The trusted key fingerprint.",
        "handoff" => "Provide the key fingerprint with the signed manifest."
      }
    ]

    supplied = [%{"acceptance" => @acceptance, "path" => evidence["path"], "sha256" => evidence["sha256"]}]
    assert :ok = ExternalHandoff.validate_evidence(conditions, supplied, [])
  end

  test "removing a resolved blocker does not make rejected evidence fresh" do
    context = context!()
    [condition] = external_review()["blockers"]
    other = %{condition | "acceptance" => "Another external acceptance"}
    a_path = Path.join(context.root, "a.txt")
    b_path = Path.join(context.root, "b.txt")
    File.write!(a_path, "unchanged A")
    File.write!(b_path, "old B")
    a = %{"acceptance" => @acceptance, "path" => a_path, "sha256" => digest(File.read!(a_path))}
    b = %{"acceptance" => other["acceptance"], "path" => b_path, "sha256" => digest(File.read!(b_path))}
    history = [[a, b]]
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence([condition], [a], history)
    File.write!(b_path, "new B")
    fresh_b = %{b | "sha256" => digest(File.read!(b_path))}
    assert :ok = ExternalHandoff.validate_evidence([condition, other], [a, fresh_b], history)
  end

  test "new code defects after external resume are commented and old-candidate evidence is cleared before recoding" do
    context = context!()
    config = settings()
    [external] = external_review()["blockers"]
    defect = %{external | "kind" => "code_defect", "reason" => "The signed-feed parser accepts invalid signatures", "required_evidence" => "", "handoff" => ""}
    rejected = external_review() |> Map.put("summary", "A code defect was found after importing evidence") |> Map.put("blockers", [defect])
    Process.put({context.key, :reviews}, [external_review(), rejected, external_review()])
    original_agent = agent(context)

    changing_agent = fn workspace, prompt, issue, opts ->
      result = original_agent.(workspace, prompt, issue, opts)
      if agent_role(opts) == :coder, do: File.write!(Path.join(workspace, "candidate.txt"), "candidate #{length(calls(context, :coder))}\n")
      result
    end

    opts = Keyword.put(options(context), :agent, changing_agent)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)
    before = Receipt.read(context.receipt)
    proof = evidence_file!(context, "proof bound to the first candidate")
    auth = authorization(context, before["external_handoff"], proof, "external-new-defect")
    assert {:error, {:mvp_awaiting_external, _}} = Executor.resume_external(resume_context(context, config, opts), digest(File.read!(context.receipt)), auth)
    [first_review, resumed_review, new_review] = calls(context, :reviewer)
    assert first_review.sha == resumed_review.sha
    assert new_review.sha != first_review.sha
    assert resumed_review.prompt =~ "external-evidence/evidence-1.bin"
    refute new_review.prompt =~ "external-evidence/evidence-1.bin"
    data = Receipt.read(context.receipt)
    assert data["external_feedback"]["external-new-defect"]["id"] == 17
    assert data["external_feedback"]["external-new-defect"]["candidate_sha"] == first_review.sha
    assert hd(data["rounds"])["comment"]["id"] == 17
    assert length(calls(context, :coder)) == 2
    assert calls(context, :publish) == []
  end

  test "a coder producing no implementation cannot reclassify that failure as external" do
    context = context!()
    Process.put({context.key, :diagnosis_action}, "await_external")
    original_agent = agent(context)

    no_change_agent = fn workspace, prompt, issue, opts ->
      if agent_role(opts) == :coder, do: {:ok, %{}}, else: original_agent.(workspace, prompt, issue, opts)
    end

    opts = Keyword.put(options(context), :agent, no_change_agent)
    assert {:error, :mvp_invalid_diagnosis} = run(context, settings(), opts)
    assert Receipt.read(context.receipt)["status"] == "blocked"
    assert is_nil(Receipt.read(context.receipt)["external_handoff"])
    assert calls(context, :publish) == []
  end

  test "waiting time does not consume the remaining original activity budget" do
    context = context!()
    config = settings(%{"max_elapsed_ms" => 10_000})
    opts = options(context)
    Process.put({context.key, :reviews}, [external_review(), approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)
    before = Receipt.read(context.receipt)
    {:ok, waiting_since, _} = DateTime.from_iso8601(before["external_handoff"]["started_at"])
    now = DateTime.to_unix(waiting_since, :millisecond)
    waited = 172_800_000
    resume_opts = Keyword.put(opts, :now_ms, fn -> now + waited end)
    proof = evidence_file!(context, "new feed proof after two days")
    auth = authorization(context, before["external_handoff"], proof, "long-wait")
    assert {:ok, @url} = Executor.resume_external(resume_context(context, config, resume_opts), digest(File.read!(context.receipt)), auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["recovery"]["external_wait_ms"] == waited
    assert after_data["recovery"]["policy"] == before["recovery"]["policy"]
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_data["rework_count"] == before["rework_count"]
  end

  test "mixed blockers repair code before parking the new candidate" do
    context = context!()
    missing_code = %{"acceptance" => "Parser rejects invalid signatures", "tests" => [], "assertion_strength" => "missing", "failure_sensitivity" => "missing", "adequate" => false}
    defect = %{"acceptance" => missing_code["acceptance"], "kind" => "code_defect", "reason" => "The parser accepts invalid data", "required_evidence" => "", "handoff" => ""}
    mixed = external_review() |> Map.update!("criteria", &(&1 ++ [missing_code])) |> Map.update!("blockers", &(&1 ++ [defect]))
    Process.put({context.key, :reviews}, [mixed, external_review()])
    original_agent = agent(context)

    changed_agent = fn workspace, prompt, issue, options ->
      result = original_agent.(workspace, prompt, issue, options)
      if agent_role(options) == :coder, do: File.write!(Path.join(workspace, "candidate.txt"), "candidate #{length(calls(context, :coder))}\n")
      result
    end

    opts = Keyword.put(options(context), :agent, changed_agent)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings(), opts)
    data = Receipt.read(context.receipt)
    [first, second] = data["rounds"]
    assert first["review"] == mixed
    assert first["candidate_sha"] != second["candidate_sha"]
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :reviewer)) == 2
    assert calls(context, :publish) == []
    assert data["external_handoff"]["conditions"] == external_review()["blockers"]
  end

  test "an unknown external check failure has an actionable diagnostic handoff and can resume" do
    context = context!()
    counter = Path.join(context.root, "service-availability")
    script = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); sys.exit(1 if n==1 else 0)"
    config = %{settings() | checks: [["python3", "-c", script, counter]]}
    Process.put({context.key, :diagnosis_action}, "await_external")
    Process.put({context.key, :reviews}, [approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, options(context))
    data = Receipt.read(context.receipt)
    assert data["external_handoff"]["source"] == "diagnosis"
    assert calls(context, :reviewer) == []
    proof = evidence_file!(context, "service restored")
    auth = authorization(context, data["external_handoff"], proof, "diagnostic-resume")
    assert {:ok, @url} = Executor.resume_external(resume_context(context, config, options(context)), digest(File.read!(context.receipt)), auth)
    assert File.read!(counter) == "2"
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1
  end

  test "a diagnosis handoff receives a new code review comment before authorized repair resumes" do
    context = context!()
    counter = Path.join(context.root, "diagnosis-check-count")
    script = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); sys.exit(1 if n==1 else 0)"
    config = %{settings(%{"max_elapsed_ms" => 30_000}) | checks: [["python3", "-c", script, counter]]}
    Process.put({context.key, :diagnosis_action}, "await_external")
    Process.put({context.key, :reviews}, [code_defect_review(), approved_review()])
    opts = timed_options(context) |> Keyword.put(:agent, changing_agent(context)) |> Keyword.put(:request_fun, expiring_comment_request(context))

    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)
    waiting = Receipt.read(context.receipt)
    assert is_nil(List.last(waiting["rounds"])["comment"])
    assert waiting["external_handoff"]["source"] == "diagnosis"

    evidence = evidence_file!(context, "signed-feed-proof")
    external_auth = authorization(context, waiting["external_handoff"], evidence, "diagnosis-code-review")
    resume = resume_context(context, config, opts)

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), external_auth)

    blocked = Receipt.read(context.receipt)
    [round] = blocked["rounds"]
    assert round["review"] == code_defect_review()
    assert round["comment"]["id"] == 17
    assert blocked["external_feedback"]["diagnosis-code-review"]["id"] == 17
    assert blocked["status"] == "blocked"
    assert length(calls(context, :coder)) == 1

    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)

    recovery_auth =
      recovery_authorization(context, "repair-after-external-review", workspace_sha, "diagnosis-code-review")

    resume = resume_context(context, config, opts)

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), recovery_auth)

    [initial_coder, repaired_coder] = calls(context, :coder)
    assert repaired_coder.prompt =~ "code_defect"
    assert repaired_coder.prompt =~ "invalid signatures"
    refute repaired_coder.sha == initial_coder.sha
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :publish)) == 1
  end

  test "external check failure clears the old rejection and later recovery reuses its imported evidence" do
    context = context!()
    counter = Path.join(context.root, "resume-check-count")
    script = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); sys.exit(10 if n==2 else 0)"
    config = %{settings(%{"max_elapsed_ms" => 30_000}) | checks: [["python3", "-c", script, counter]]}
    Process.put({context.key, :reviews}, [external_review()])
    opts = timed_options(context)

    assert {:error, {:mvp_awaiting_external, _}} = run(context, config, opts)
    before = Receipt.read(context.receipt)
    [original_round] = before["rounds"]
    assert original_round["review"] == external_review()
    assert original_round["comment"]["id"] == 17

    proof = evidence_file!(context, "signed-feed-proof-needed-by-reviewer")
    external_auth = authorization(context, before["external_handoff"], proof, "external-check-failure")
    Process.put({context.key, :expire_on_check}, true)
    resume = resume_context(context, config, opts)

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_external(resume, digest(File.read!(context.receipt)), external_auth)

    blocked = Receipt.read(context.receipt)
    [failed_round] = blocked["rounds"]
    [saved_proof] = List.last(blocked["external_evidence_history"])
    assert is_nil(failed_round["review"])
    assert is_nil(failed_round["review_path"])
    assert is_nil(failed_round["comment"])
    assert is_map(failed_round["check_failure"])
    assert is_nil(blocked["review"])
    assert is_nil(blocked["review_path"])
    assert is_nil(blocked["comment"])
    assert File.regular?(Path.join([context.receipt <> ".evidence", "operator-rechecks", "external-check-failure", "receipt-before.json"]))
    assert Jason.decode!(File.read!(Path.join([context.receipt <> ".evidence", "operator-rechecks", "external-check-failure", "receipt-before.json"]))) == before
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1

    Process.put({context.key, :reviews}, [approved_review()])
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)

    recovery_auth =
      recovery_authorization(context, "recover-imported-external-proof", workspace_sha, "external-check-failure")

    resume = resume_context(context, config, opts)

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), recovery_auth)

    [initial_review, recovered_review] = calls(context, :reviewer)
    assert initial_review.sha == recovered_review.sha
    assert File.read!(saved_proof["path"]) == "signed-feed-proof-needed-by-reviewer"
    assert recovered_review.prompt =~ saved_proof["path"]
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :publish)) == 1
  end

  test "the CLI resumes a controller-generated handoff through the real executor" do
    context = context!()
    workflow = Path.join(context.root, "WORKFLOW.md")
    original = settings()

    config = %{
      "tracker" => %{"kind" => "github", "provider" => %{"repo" => "owner/repo", "token" => "test-token"}, "required_labels" => ["ready"], "active_states" => ["open"], "terminal_states" => ["closed"]},
      "workspace" => %{"root" => Path.join(context.root, "workspaces")},
      "agent" => %{"max_concurrent_agents" => 1},
      "codex" => %{"command" => "codex app-server", "thread_sandbox" => "workspace-write"},
      "mvp" => %{
        "enabled" => true,
        "coder_model" => "coder-model",
        "reviewer_model" => "reviewer-model",
        "allowed_models" => ["coder-model", "reviewer-model"],
        "allowed_actors" => ["alice"],
        "checks" => original.checks,
        "check_timeout_ms" => original.check_timeout_ms,
        "max_rework" => original.max_rework,
        "recovery" => original.recovery,
        "state_dir" => Path.dirname(context.receipt)
      }
    }

    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nLocal fixture\n")
    {:ok, loaded} = Workflow.load(workflow)
    {:ok, configured} = MvpConfig.settings(loaded, context.root)
    {:ok, app_settings} = Schema.parse(loaded.config)
    Process.put({context.key, :reviews}, [external_review(), approved_review()])
    assert {:error, {:mvp_awaiting_external, _}} = run(context, configured, options(context))
    waiting = Receipt.read(context.receipt)
    evidence = evidence_file!(context, "signed-feed-from-operator")
    auth = authorization(context, waiting["external_handoff"], evidence, "cli-resume") |> Map.delete("handoff_id")
    request = Path.join(context.root, "REQUEST.json")
    File.write!(request, Jason.encode!(%{"receipt_sha256" => digest(File.read!(context.receipt)), "authorization" => auth}))

    delegate = fn frozen, receipt_digest, authorization ->
      Executor.resume_external(%{frozen | opts: Keyword.merge(frozen.opts, options(context))}, receipt_digest, authorization)
    end

    assert {:ok, @url} =
             External.resume(workflow, context.receipt, request,
               runtime_validator: fn _ -> :ok end,
               ensure_request_runtime: fn -> {:ok, []} end,
               tracker_binding: app_settings.tracker,
               fetch_issue: fn _, _, _ -> {:ok, [context.issue]} end,
               resolve_models: fn _, _, _ -> {:ok, models()} end,
               resume_external: delegate
             )

    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :publish)) == 1
    assert File.regular?(Path.join([context.receipt <> ".evidence", "operator-rechecks", "cli-resume", "check-1.log"]))
  end

  # The bridge and AppServer seams are synthetic; Git, frozen handoff, evidence,
  # budget accounting, checks, Review and Draft PR reconciliation run normally.
  defp automatic_waiting!(kind, policy \\ %{}, park \\ true) do
    context = context!()

    automatic_accounts!()

    authority = ServiceFixture.settings(Path.join(context.root, "authority"))
    trusted = Path.join(context.root, "trusted")
    File.mkdir_p!(Path.join(trusted, "scripts"))
    File.write!(Path.join(trusted, "scripts/probe_rootless.py"), "fixed test probe\n")
    File.write!(Path.join(trusted, "scripts/execution_sandbox.sh"), "printf '%s' '{\"status\":\"ready\",\"backend\":\"rootless\"}'\n")

    config = %{
      "enabled" => true,
      "backend" => "rootless",
      "profile" => "rootless-open-v1",
      "network" => "public-egress-v1",
      "image" => "fixture@sha256:" <> String.duplicate("a", 64),
      "worker" => "fixture-worker",
      "root" => Path.join(context.root, "sandboxes"),
      "toolchain" => Path.join(trusted, "toolchain"),
      "codex" => Path.join(trusted, "codex"),
      "dependencies" => Path.join(trusted, "dependencies"),
      "trusted_root" => trusted,
      "auth_home" => Path.join(context.root, "auth")
    }

    {:ok, sandbox} = ExecutionSandbox.settings(config)
    {:ok, runner} = AutomaticAcceptance.runner_digest(%{settings: %{sandbox: sandbox}}, kind)
    profiles = %{@acceptance => %{"kind" => kind, "runner_sha256" => runner, "timeout_ms" => 60_000}}
    settings = Map.merge(authority, settings(policy)) |> Map.put(:sandbox, Map.put(sandbox, "acceptance_profiles", profiles)) |> Map.put(:checks, [["python3", "scripts/check_candidate.py"]])
    settings = Map.put(settings, :model_command, config["codex"] <> " app-server")

    registry =
      Enum.reduce([{:coder, "coding"}, {:reviewer, "reviewing"}], settings.model_services, fn {role, id}, registry ->
        {:ok, service} = ModelServices.snapshot(%{settings | model_services: registry}, id, role, "fixture")
        {:ok, registry} = ModelCatalog.attest(registry, service, ServiceFixture.proof(role))
        registry
      end)

    settings = %{settings | model_services: registry}
    ServiceFixture.write_authority!(settings)

    services =
      Map.new([{:coder, "coding"}, {:reviewer, "reviewing"}], fn {role, id} ->
        {:ok, service} = ModelServices.snapshot(settings, id, role, "fixture")
        {Atom.to_string(role), service}
      end)

    selected = %{coder: "gpt-test", reviewer: "gpt-test", services: services}
    Process.put({context.key, :reviews}, [verification_review(), approved_review()])
    Process.put({context.key, :park_automatic}, park)

    opts =
      draft_options(context)
      |> Keyword.put(:sandbox_cleanup_timeout_ms, 1)
      |> Keyword.put(:sandbox_command_run, automatic_command(context))
      |> Keyword.put(:sandbox_agent_run, automatic_agent(context))

    result = Executor.run(context.workspace, context.issue, settings, selected, context.receipt, opts)
    if park, do: assert(match?({:error, {:mvp_awaiting_external, _}}, result)), else: assert(result == {:ok, @url})
    evidence = context.receipt <> ".evidence"
    if park, do: File.rm!(Path.join(evidence, "operator-recheck.lock"))
    resume_context(context, settings, opts) |> Map.put(:models, Map.take(selected, [:coder, :reviewer])) |> Map.put(:services, services)
  end

  defp automatic_command(context) do
    fn argv, _workspace, timeout, log_path ->
      scratch = automatic_argument(argv, "--scratch-root")
      probe? = Enum.any?(argv, &String.ends_with?(&1, "/probe_rootless.py"))
      record(context, if(probe?, do: :probe, else: :formal_check), %{argv: argv, timeout: timeout})
      outcome = if probe?, do: Process.get({context.key, :probe_outcome}, :passed), else: :passed
      status = if outcome == :failed, do: 124, else: 0
      automatic_result!(scratch, status)
      if outcome != :missing_export, do: File.mkdir_p!(Path.join(scratch, "export/.check-evidence"))
      File.write!(log_path, "fixed bridge result #{status}\n")
      if outcome == :evidence_collision, do: File.write!(Path.join(Path.dirname(log_path), "probe-0.json"), "existing evidence")
      {:ok, status}
    end
  end

  defp automatic_accounts! do
    unless Process.get(:automatic_accounts_registered) do
      previous = Map.new(~w(GH12_CODER_KEY GH12_REVIEWER_KEY), &{&1, System.get_env(&1)})
      on_exit(fn -> restore_accounts(previous) end)
      Process.put(:automatic_accounts_registered, true)
    end

    for name <- ~w(GH12_CODER_KEY GH12_REVIEWER_KEY), do: System.put_env(name, "synthetic-acceptance-account")
  end

  defp restore_accounts(previous), do: Enum.each(previous, fn {name, value} -> restore_account(name, value) end)
  defp restore_account(name, nil), do: System.delete_env(name)
  defp restore_account(name, value), do: System.put_env(name, value)

  defp automatic_agent(context) do
    original = agent(context)

    fn workspace, prompt, issue, opts ->
      scratch = Path.join(Path.dirname(opts[:execution_environment].codex_home), "sandbox")
      automatic_result!(scratch, 0)

      cond do
        String.starts_with?(prompt, "Fixed model connection probe.") ->
          automatic_model_probe(context, prompt, opts)

        opts[:read_only] ->
          park_automatic_job(context)
          original.(workspace, prompt, issue, opts)

        true ->
          automatic_coder(context, workspace, prompt, opts, scratch)
      end
    end
  end

  defp automatic_model_probe(context, prompt, opts) do
    assert opts[:tools] == false
    assert opts[:read_only] == true
    assert opts[:execution_environment].read_only
    assert opts[:turn_protocol] == "codex-0.160.0-turn-v1"
    record(context, :probe, %{options: opts})
    opts[:on_message].(%{usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}})
    [json] = Regex.run(~r/\{"candidate_sha":"[a-f0-9]+","probe":"[a-f0-9]+"\}/, prompt)
    expected = Jason.decode!(json)

    case Process.get({context.key, :probe_outcome}, :passed) do
      :failed -> {:error, :model_service_unavailable}
      :bad_json -> {:ok, %{output_text: "not json"}}
      :wrong_nonce -> {:ok, %{output_text: Jason.encode!(Map.put(expected, "probe", "wrong"))}}
      :wrong_candidate -> {:ok, %{output_text: Jason.encode!(Map.put(expected, "candidate_sha", String.duplicate("b", 40)))}}
      :passed -> {:ok, %{output_text: json, actual_model: nil}}
    end
  end

  defp park_automatic_job(context) do
    if Process.get({context.key, :park_automatic}, false) do
      File.write!(Path.join(context.receipt <> ".evidence", "operator-recheck.lock"), "test pause before automatic job")
      Process.put({context.key, :park_automatic}, false)
    end
  end

  defp automatic_coder(context, workspace, prompt, opts, scratch) do
    export = Path.join(scratch, "export")
    File.mkdir_p!(export)
    for name <- File.ls!(workspace), name != ".git", do: File.cp_r!(Path.join(workspace, name), Path.join(export, name))
    File.write!(Path.join(export, "candidate.txt"), "candidate\n")
    record(context, :coder, %{prompt: prompt})
    opts[:on_message].(%{usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}})
    {:ok, %{output_text: "Implemented the candidate"}}
  end

  defp automatic_result!(scratch, status) do
    File.mkdir_p!(scratch)
    File.write!(Path.join(scratch, "result.json"), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true, "scratch_root" => scratch, "exit_status" => status}))
  end

  defp automatic_argument(argv, flag), do: argv |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
  defp automatic_directory(context), do: Path.join([context.evidence, "acceptance-jobs", Receipt.read(context.receipt)["external_handoff"]["id"]])
  defp automatic_completion(context), do: automatic_directory(context) |> Path.join("completion.json") |> File.read!() |> Jason.decode!()

  defp context! do
    root = Path.join(System.tmp_dir!(), "mvp-external-handoff-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base source\n")
    Commands.git!(["add", "source.txt"], workspace)
    Commands.git!(["commit", "-m", "initial"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["remote", "add", "origin", remote], workspace)
    Commands.git!(["push", "--set-upstream", "origin", "main"], workspace)
    Commands.git!(["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"], root)

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Use the signed company feed",
      description: @acceptance,
      native_ref: %{"repo" => "owner/repo", "number" => 42},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)

    %{
      root: root,
      workspace: workspace,
      repository: %{repo: "owner/repo", base: "main", url: remote},
      issue: issue,
      receipt: receipt,
      key: make_ref()
    }
  end

  defp add_ignored_cache!(context, size) do
    cache = Path.join(context.workspace, "cache.bin")
    File.write!(Path.join(context.workspace, ".gitignore"), "cache.bin\n")
    File.write!(cache, :binary.copy("a", size))
    Commands.git!(["add", ".gitignore"], context.workspace)
    Commands.git!(["commit", "-m", "Add ignored cache race fixture"], context.workspace)
    Commands.git!(["push", "origin", "main"], context.workspace)
    cache
  end

  defp wait_for_file!(path) do
    wait_until!(fn -> File.regular?(path) end, "file #{path}")
  end

  defp wait_until!(ready?, description) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    wait_until!(ready?, description, deadline)
  end

  defp wait_until!(ready?, description, deadline) do
    cond do
      ready?.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "timed out waiting for #{description}"

      true ->
        Process.sleep(1)
        wait_until!(ready?, description, deadline)
    end
  end

  defp settings(overrides \\ %{}) do
    policy_config = Map.merge(%{"enabled" => true, "max_agent_attempts" => 16}, overrides)
    {:ok, recovery} = Recovery.settings(policy_config)
    %{checks: [["test", "-f", "{workspace}/candidate.txt"]], check_timeout_ms: 10_000, max_rework: 5, recovery: recovery, sandbox: %{enabled: false}}
  end

  defp run(context, settings, opts), do: Executor.run(context.workspace, context.issue, settings, models(), context.receipt, opts)

  defp options(context) do
    [
      repository: fn _, _ -> {:ok, context.repository} end,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}},
      agent: agent(context),
      request_fun: comment_request(),
      publish: fn _, _, _, _, _, _, _ ->
        record(context, :publish, :called)
        {:ok, @url}
      end
    ]
  end

  defp timed_options(context) do
    options(context)
    |> Keyword.put(:now_ms, fn -> controlled_now(context) end)
    |> Keyword.put(:on_message, fn
      %{event: :mvp_check_started} ->
        if Process.get({context.key, :expire_on_check}, false) do
          expire_activity_budget(context)
          Process.put({context.key, :expire_on_check}, false)
        end

      _message ->
        :ok
    end)
  end

  defp changing_agent(context) do
    original = agent(context)

    fn workspace, prompt, issue, opts ->
      role = agent_role(opts)
      result = original.(workspace, prompt, issue, opts)

      if role == :coder do
        File.write!(Path.join(workspace, "candidate.txt"), "candidate #{length(calls(context, :coder))}\n")
      end

      result
    end
  end

  defp controlled_now(context) do
    case Process.get({context.key, :now_ms}) do
      now when is_integer(now) -> now
      _ -> System.system_time(:millisecond)
    end
  end

  defp expire_activity_budget(context) do
    recovery = Receipt.read(context.receipt)["recovery"]
    {:ok, started, _} = DateTime.from_iso8601(recovery["started_at"])
    credited_wait = recovery["external_wait_ms"] || 0
    expired = DateTime.to_unix(started, :millisecond) + recovery["policy"]["max_elapsed_ms"] + credited_wait + 1_000
    Process.put({context.key, :now_ms}, expired)
  end

  defp recovery_authorization(_context, id, workspace_sha, predecessor) do
    %{
      "id" => id,
      "authorization" => "Explicit bounded recovery authorization for this test",
      "runtime_version" => String.duplicate("b", 40),
      "command" => ["mix", "mvp.recovery", "resume", id],
      "diagnostic" => "Continue from the latest confirmed review and check evidence",
      "legacy_closures" => [],
      "predecessor" => predecessor,
      "workspace_digest" => workspace_sha,
      "wall_budget_extension_ms" => 10_000
    }
  end

  defp agent(context) do
    fn workspace, prompt, _issue, opts ->
      role = agent_role(opts)
      record(context, role, %{prompt: prompt, sha: Commands.git!(["rev-parse", "HEAD"], workspace)})
      opts[:on_message].(%{usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}})

      agent_output(context, workspace, role)
    end
  end

  defp agent_output(context, workspace, role) do
    case role do
      :coder ->
        File.write!(Path.join(workspace, "candidate.txt"), "candidate\n")
        {:ok, %{output_text: "Implemented the repository change"}}

      :reviewer ->
        [review | rest] = Process.get({context.key, :reviews})
        Process.put({context.key, :reviews}, rest)
        {:ok, %{output_text: Jason.encode!(review)}}

      :diagnosis ->
        action = Process.get({context.key, :diagnosis_action}, "repair_code")
        conditions = external_review()["blockers"]
        diagnosis = %{"action" => action, "summary" => "The package registry is unavailable", "steps" => ["Request signed feed proof"]}
        diagnosis = if action == "await_external", do: Map.put(diagnosis, "external_conditions", conditions), else: diagnosis
        {:ok, %{output_text: Jason.encode!(diagnosis)}}
    end
  end

  defp agent_role(opts) do
    required = Map.get(Keyword.get(opts, :output_schema, %{}), "required", [])

    cond do
      "action" in required -> :diagnosis
      opts[:read_only] == true -> :reviewer
      true -> :coder
    end
  end

  defp comment_request do
    fn "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _ ->
      {:ok, %{status: 201, body: %{"id" => 17, "body" => body["body"]}}}
    end
  end

  defp expiring_comment_request(context) do
    original = comment_request()

    fn method, path, params, body, opts ->
      result = original.(method, path, params, body, opts)
      if String.contains?(body["body"], "code_defect"), do: expire_activity_budget(context)
      result
    end
  end

  defp resume_context(context, settings, opts) do
    data = Receipt.read(context.receipt)
    evidence = context.receipt <> ".evidence"
    baseline = Path.join(evidence, "baseline")

    Map.merge(context, %{
      settings: settings,
      models: models(),
      opts: opts,
      branch: data["branch"],
      evidence: evidence,
      base: data["base_sha"],
      metadata: metadata(context.workspace),
      baseline_digest: tree_digest(baseline),
      limit: Recovery.limit(settings)
    })
  end

  defp update_handoff_record(context, update) do
    data = Receipt.read(context.receipt)
    handoff = data["external_handoff"]
    record = Jason.decode!(File.read!(handoff["record_path"])) |> update.()
    raw = Jason.encode!(record, pretty: true)
    File.write!(handoff["record_path"], raw)

    updated_handoff = Map.merge(record, %{"record_path" => handoff["record_path"], "record_sha256" => digest(raw)})
    Receipt.update(context.receipt, data["status"], %{"external_handoff" => updated_handoff})
  end

  defp metadata(workspace) do
    Map.new([".git/config", ".git/info/attributes", ".git/info/exclude"], &{&1, File.read(Path.join(workspace, &1))})
  end

  defp tree_digest(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path ->
      relative = Path.relative_to(path, root)

      case File.lstat!(path) do
        %{type: :regular} -> {relative, :crypto.hash(:sha256, File.read!(path))}
        %{type: :symlink} -> {relative, File.read_link!(path)}
        %{type: type} -> {relative, type}
      end
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp authorization(context, handoff, evidence, id) do
    %{
      "id" => id,
      "authorization" => "Explicit local test authorization",
      "runtime_version" => String.duplicate("a", 40),
      "command" => ["mix", "mvp.external", "resume"],
      "diagnostic" => "The operator supplied the requested acceptance evidence",
      "predecessor" => Receipt.read(context.receipt)["operator_recheck"],
      "legacy_closures" => [],
      "external_evidence" => [%{"acceptance" => @acceptance, "path" => evidence["path"], "sha256" => evidence["sha256"]}],
      "handoff_id" => handoff["id"]
    }
  end

  defp evidence_file!(context, contents) do
    path = Path.join(context.root, "operator-evidence.txt")
    File.write!(path, contents)
    %{"path" => path, "sha256" => digest(File.read!(path))}
  end

  defp external_review do
    %{
      "approved" => false,
      "summary" => "The external feed signature cannot be confirmed from this workspace.",
      "criteria" => [criterion(false)],
      "blockers" => [
        %{
          "acceptance" => @acceptance,
          "kind" => "external_condition",
          "reason" => "The company feed signing key is not available to this task.",
          "required_evidence" => "A signed feed manifest and key fingerprint.",
          "handoff" => "Ask the repository owner to provide the signed manifest and fingerprint."
        }
      ]
    }
  end

  defp code_defect_review do
    [external] = external_review()["blockers"]

    defect = %{
      external
      | "kind" => "code_defect",
        "reason" => "The parser accepts invalid signatures",
        "required_evidence" => "",
        "handoff" => ""
    }

    external_review()
    |> Map.put("summary", "The imported feed proof did not resolve the parser defect.")
    |> Map.put("blockers", [defect])
  end

  defp approved_review do
    %{"approved" => true, "summary" => "The candidate and supplied feed evidence satisfy acceptance.", "criteria" => [criterion(true)], "blockers" => []}
  end

  defp criterion(adequate) do
    %{
      "acceptance" => @acceptance,
      "tests" => if(adequate, do: ["test/acceptance_test.exs validates the signed feed"], else: []),
      "assertion_strength" => "Checks the feed signature result",
      "failure_sensitivity" => "An invalid signature is rejected",
      "adequate" => adequate
    }
  end

  defp models, do: %{coder: "coder-model", reviewer: "reviewer-model"}
  defp calls(context, role), do: Process.get({context.key, role}, [])
  defp record(context, role, value), do: Process.put({context.key, role}, calls(context, role) ++ [value])
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
