defmodule SymphonyElixir.Mvp.RecoveryExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ModelServicesFixture, as: ServiceFixture

  alias SymphonyElixir.Mvp.{
    Commands,
    DeepSeek,
    Delivery,
    ExecutionSandbox,
    Executor,
    Intake,
    ModelCatalog,
    ModelServices,
    Receipt,
    Recovery
  }

  @url "https://github.com/owner/repo/pull/42"

  test "GitLab review rejection repairs a new candidate and delivers one verified Draft MR" do
    context = gitlab_context!()
    trace = Path.join(context.root, "checks.log")
    opts = gitlab_options(context, review: fn count -> count > 1 end)
    assert {:ok, url} = run(context, settings([trace_check(trace)]), opts)
    assert url == "https://gitlab.example/owner/repo/-/merge_requests/9"
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :comment)) == 1
    assert length(calls(context, :mr_created)) == 1
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_human"
    assert data["review"]["approved"]
    assert File.read!(trace) == "1\n2\n"
    assert Commands.git!(["--git-dir", context.repository.url, "rev-parse", "refs/heads/" <> data["branch"]], context.root) == data["candidate_sha"]
    assert {:ok, ^url} = Delivery.reconcile(context.receipt, opts)
    assert length(calls(context, :mr_created)) == 1
  end

  test "GitLab external verification creates a pending Draft once and only reconciles reads" do
    context = gitlab_context!()
    opts = gitlab_options(context, external_review: true)
    assert {:error, {:mvp_awaiting_external, _}} = run(context, settings([["true"]]), opts)
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_external"
    assert data["external_delivery"]["status"] == "delivered"
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :mr_created)) == 1
    assert {:ok, _} = Delivery.reconcile(context.receipt, opts)
    assert {:ok, _} = Delivery.reconcile(context.receipt, opts)
    assert Receipt.read(context.receipt)["status"] == "awaiting_external"
    assert length(calls(context, :mr_created)) == 1
  end

  test "automatic recovery exceeds five reworks, reruns every check and publishes only after independent review" do
    context = context!()
    trace = Path.join(context.root, "check-runs.txt")
    checks = [trace_check(trace), numeric_check(8)]

    assert {:ok, @url} = run(context, settings(checks), options(context))

    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 7
    assert length(data["rounds"]) == 8
    assert File.read!(trace) |> String.split("\n", trim: true) == Enum.map(1..8, &Integer.to_string/1)
    assert length(calls(context, :coder)) == 8
    assert length(calls(context, :diagnosis)) >= 2
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :publish)) == 1
    assert hd(calls(context, :publish)).sha == List.last(data["rounds"])["candidate_sha"]

    for round <- data["rounds"] do
      assert round["base_sha"] == data["base_sha"]
      assert round["models"] == %{"coder" => "coder-model", "reviewer" => "reviewer-model"}
      assert File.regular?(Path.join(round["evidence"], "check-1.log"))
      check = Path.join(round["evidence"], "check-2.json") |> File.read!() |> Jason.decode!()
      assert check["exit_status"] == if(round["round"] == 8, do: 0, else: 10)
    end

    for call <- calls(context, :diagnosis) do
      assert call.model == "coder-model"
      assert call.read_only
      assert call.prompt =~ "Do not modify files"
    end

    assert hd(calls(context, :reviewer)).model == "reviewer-model"
    refute File.exists?(Path.join(context.root, "origin.git/refs/heads/codex"))
  end

  test "a valid review rejection is commented once and diagnosis retry_stage repairs a new candidate" do
    context = context!()
    opts = options(context, review: fn count -> count > 1 end, diagnosis: "retry_stage")

    assert {:ok, @url} = run(context, settings([["true"]], %{"diagnose_every" => 1}), opts)
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :reviewer)) == 2
    assert length(calls(context, :diagnosis)) == 1
    assert length(calls(context, :comment)) == 1
    assert length(calls(context, :publish)) == 1
    [first, second] = calls(context, :reviewer)
    refute first.sha == second.sha
    [first_round, second_round] = Receipt.read(context.receipt)["rounds"]
    assert first_round["review"]["approved"] == false
    assert first_round["comment"]["id"] == 1
    assert first_round["comment"]["candidate_sha"] == first.sha
    assert second_round["review"]["approved"]
  end

  test "DeepSeek fenced diagnosis retries malformed output, retaining raw evidence, read-only roles and candidate binding" do
    context = context!()
    for key <- ~w(GH12_CODER_KEY GH12_REVIEWER_KEY), do: System.put_env(key, "synthetic-deepseek")
    on_exit(fn -> for key <- ~w(GH12_CODER_KEY GH12_REVIEWER_KEY), do: System.delete_env(key) end)
    authority = ServiceFixture.settings(Path.join(context.root, "authority"), %{"reasoning_effort" => "high"}, "deepseek")
    config = Map.merge(settings([["true"]], %{"diagnose_every" => 1}), authority)
    {:ok, selected} = Intake.resolve_comments([], config)
    opts = options(context, review: fn count -> count > 1 end, diagnosis: "retry_stage")
    agent = opts[:agent]

    opts =
      Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
        {:ok, result} = agent.(workspace, prompt, issue, options)
        role = agent_role(options)
        assert options[:model_service] == selected.services[if(role == :reviewer, do: "reviewer", else: "coder")]
        fenced = "```json\n#{result.output_text}\n```"
        text = if role == :diagnosis and length(calls(context, :diagnosis)) == 1, do: "Diagnosis:\n" <> fenced, else: fenced
        if role == :coder, do: {:ok, result}, else: {:ok, %{result | output_text: text}}
      end)

    assert {:ok, @url} = Executor.run(context.workspace, context.issue, config, selected, context.receipt, opts)
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :diagnosis)) == 2
    assert length(calls(context, :comment)) == 1
    [first, final] = calls(context, :reviewer)
    refute first.sha == final.sha
    assert first.read_only and final.read_only
    assert hd(calls(context, :diagnosis)).read_only
    assert final.prompt =~ final.sha
    assert [%{sha: sha}] = calls(context, :publish)
    assert sha == final.sha
    [rejected, approved] = Receipt.read(context.receipt)["rounds"]
    refute rejected["review"]["approved"]
    assert rejected["comment"]["candidate_sha"] == first.sha
    assert approved["review"]["approved"]
    assert approved["candidate_sha"] == sha
    events = Receipt.read(context.receipt)["recovery"]["events"]

    for event <- events, event["role"] == "diagnosis" do
      raw = File.read!(Path.join(event["evidence"], "output.txt"))
      outcome = File.read!(Path.join(event["evidence"], "outcome.json")) |> Jason.decode!()
      assert raw =~ "```json"
      normalized = DeepSeek.normalize_structured_output(raw, selected.services["coder"])
      assert outcome["result"] =~ "normalized_output_text: " <> inspect(normalized)
      assert outcome["result"] =~ "output_text: " <> inspect(raw)
    end
  end

  test "legacy OpenAI fenced diagnosis exhausts bounded retries without approving or publishing" do
    context = context!()
    opts = options(context, diagnosis: "retry_stage")
    agent = opts[:agent]

    opts =
      Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
        {:ok, result} = agent.(workspace, prompt, issue, options)
        if agent_role(options) == :diagnosis, do: {:ok, %{result | output_text: "```json\n#{result.output_text}\n```"}}, else: {:ok, result}
      end)

    assert {:error, :mvp_invalid_diagnosis} = run(context, settings([["false"]]), opts)
    assert length(calls(context, :diagnosis)) == 3
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
  end

  test "an unknown check failure can retry trusted checks on the same SHA without recoding" do
    context = context!()
    counter = Path.join(context.root, "transient-count.txt")
    code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); print(n); sys.exit(1 if n==1 else 0)"
    check = ["python3", "-c", code, counter]

    assert {:ok, @url} = run(context, settings([check]), options(context, diagnosis: "retry_stage"))
    assert File.read!(counter) == "2"
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "1"
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :diagnosis)) == 1
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :publish)) == 1
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 0
    assert length(data["rounds"]) == 1
    assert hd(calls(context, :diagnosis)).sha == hd(calls(context, :reviewer)).sha
    evidence = hd(data["rounds"])["evidence"]
    assert File.read!(Path.join(evidence, "check-1.log")) =~ "1"
    assert File.read!(Path.join(evidence, "check-attempt-2/check-1.log")) =~ "2"
  end

  test "stage retries, model attempts, elapsed time and total rounds stop at their respective budgets" do
    for kind <- [:stage, :attempts, :elapsed, :rounds] do
      context = context!()

      {config, opts, checks, reason} =
        case kind do
          :stage -> {%{"stage_attempts" => 2}, options(context, diagnosis: "retry_stage"), [["false"]], :mvp_recovery_stage_exhausted}
          :attempts -> {%{"max_agent_attempts" => 1}, options(context), [["true"]], :mvp_recovery_resource_exhausted}
          :elapsed -> {%{}, Keyword.put(options(context), :now_ms, fn -> System.system_time(:millisecond) + 86_400_000 end), [["true"]], :mvp_recovery_resource_exhausted}
          :rounds -> {%{"max_rework" => 1}, options(context), [numeric_check(100)], :mvp_recovery_resource_exhausted}
        end

      assert {:error, ^reason} = run(context, settings(checks, config), opts)
      assert calls(context, :publish) == []
      assert Receipt.read(context.receipt)["status"] == "blocked"

      case kind do
        :stage ->
          assert length(calls(context, :coder)) == 1
          assert length(calls(context, :diagnosis)) == 2
          refute File.exists?(context.receipt <> ".evidence/round-1/check-attempt-3")

        :attempts ->
          assert length(calls(context, :coder)) == 1
          assert calls(context, :reviewer) == []
          assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 1

        :elapsed ->
          assert calls(context, :coder) == []

        :rounds ->
          assert length(calls(context, :coder)) == 2
          assert Receipt.read(context.receipt)["rework_count"] == 1
      end
    end
  end

  test "a check that tampers with the frozen baseline stops before diagnosis or review" do
    context = context!()
    checks = [["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('tampered'); sys.exit(10)", "{baseline}/source.txt"]]
    assert {:error, :mvp_candidate_or_baseline_changed} = run(context, settings(checks), options(context))
    assert calls(context, :diagnosis) == []
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
  end

  test "adopting an exhausted legacy review preserves original evidence, models and base then repairs independently" do
    {context, raw, old_data} = exhausted_review!()
    original_files = old_evidence(old_data)
    opts = options(context)
    resume = resume_context(context, opts)

    assert {:ok, @url} = Executor.recover(resume, digest(raw), authorization("adopt-review"))
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 2
    assert data["recovery"]["adopted_rework_count"] == 1
    assert data["recovery"]["adopted_agent_attempts"] == 4
    assert data["recovery"]["agent_attempts"] == 7
    assert data["base_sha"] == old_data["base_sha"]
    assert data["models"] == old_data["models"]
    assert data["max_rework"] == 20
    assert is_nil(data["reason"])
    assert length(data["rounds"]) == 3
    assert hd(calls(context, :diagnosis)).sha == old_data["candidate_sha"]
    assert length(calls(context, :publish)) == 1
    assert List.last(calls(context, :reviewer)).sha != old_data["candidate_sha"]

    for {old, current} <- Enum.zip(old_data["rounds"], data["rounds"]) do
      assert Map.delete(current, "usage") == Map.delete(old, "usage")
      assert Map.take(current["usage"], Map.keys(old["usage"])) == old["usage"]
      assert old["usage"]["coder"]["total_tokens"] == 15
      assert old["usage"]["reviewer"]["total_tokens"] == 15
    end

    for {path, contents} <- original_files, do: assert(File.read!(path) == contents)
    assert File.read!(context.receipt <> ".evidence/operator-rechecks/adopt-review/receipt-before.json") == raw
    assert File.regular?(context.receipt <> ".evidence/operator-rechecks/adopt-review/completion.json")
    assert {:error, :mvp_resume_binding_mismatch} = Executor.recover(resume, digest(File.read!(context.receipt)), authorization("adopt-review"))
  end

  test "adoption rejects a changed legacy review JSON before creating an operation" do
    {context, raw, old_data} = exhausted_review!()
    resume = resume_context(context, options(context))
    path = Path.join(List.last(old_data["rounds"])["evidence"], "review.json")
    File.write!(path, Jason.encode!(review(true)))

    assert {:error, :mvp_recovery_evidence_mismatch} = Executor.recover(resume, digest(raw), authorization("tampered-review"))
    assert File.read!(context.receipt) == raw
    assert calls(context, :diagnosis) == []
    refute File.exists?(context.receipt <> ".evidence/operator-rechecks")
  end

  test "restoring an old receipt cannot repeat or bypass a completed adoption operation" do
    {context, raw, _old_data} = exhausted_review!()
    resume = resume_context(context, options(context, diagnosis: "stop"))
    auth = authorization("stopped-adoption")

    assert {:error, {:mvp_recovery_requires_attention, "Investigate technical failure"}} = Executor.recover(resume, digest(raw), auth)
    count = length(calls(context, :diagnosis))
    File.write!(context.receipt, raw)
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = Executor.recover(resume, digest(raw), auth)
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = Executor.recover(resume, digest(raw), authorization("another-operation"))
    assert length(calls(context, :diagnosis)) == count
    assert calls(context, :publish) == []
  end

  test "elapsed time is checked between trusted commands before launching the next check" do
    context = context!()
    clock = Path.join(context.root, "clock.txt")
    marker = Path.join(context.root, "second-check.txt")
    future = System.system_time(:millisecond) + 86_400_000
    advance_clock = ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])", clock, Integer.to_string(future)]
    second_check = ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", marker]
    now = fn -> if File.exists?(clock), do: String.to_integer(File.read!(clock)), else: System.system_time(:millisecond) end

    assert {:error, :mvp_recovery_resource_exhausted} =
             run(context, settings([advance_clock, second_check]), Keyword.put(options(context), :now_ms, now))

    assert File.regular?(clock)
    refute File.exists?(marker)
    assert File.regular?(context.receipt <> ".evidence/round-1/check-1.log")
    refute File.exists?(context.receipt <> ".evidence/round-1/check-2.log")
    assert calls(context, :reviewer) == []
    assert calls(context, :diagnosis) == []
    assert calls(context, :publish) == []
  end

  test "a coder producing no changes receives read-only diagnosis before a fresh repair" do
    context = context!()
    assert {:ok, @url} = run(context, settings([numeric_check(1)]), options(context, skip_first_coder: true))
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :diagnosis)) == 1
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :publish)) == 1
    [diagnosis] = calls(context, :diagnosis)
    assert diagnosis.read_only
    assert diagnosis.prompt =~ "produced no changes"
    assert List.last(calls(context, :coder)).prompt =~ "concrete tested repair"
    [initial, repaired] = Receipt.read(context.receipt)["rounds"]
    assert initial["candidate_sha"] == initial["base_sha"]
    refute repaired["candidate_sha"] == initial["candidate_sha"]
    refute File.exists?(Path.join(initial["evidence"], "check-1.log"))
    assert File.regular?(Path.join(repaired["evidence"], "check-1.log"))
  end

  test "an uncertain rejection comment is reconciled by one matching read without another POST" do
    context = context!()

    request = fn
      "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _ ->
        record(context, :comment, body)
        {:error, :connection_closed_after_write}

      "GET", "/repos/owner/repo/issues/42/comments", %{"per_page" => 100, "page" => 1}, nil, _ ->
        record(context, :comment_read, %{})
        [body] = calls(context, :comment)
        {:ok, %{status: 200, body: [%{"id" => 73, "body" => body["body"]}]}}
    end

    opts = options(context, review: fn count -> count > 1 end) |> Keyword.put(:request_fun, request)
    assert {:ok, @url} = run(context, settings([["true"]]), opts)
    assert length(calls(context, :comment)) == 1
    assert length(calls(context, :comment_read)) == 1
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :publish)) == 1
    assert hd(Receipt.read(context.receipt)["rounds"])["comment"]["id"] == 73
  end

  test "legacy operator review evidence is adopted from its exact audited path" do
    context = context!()
    config = %{checks: [numeric_check(3)], check_timeout_ms: 10_000, max_rework: 1}
    assert {:error, :mvp_rework_exhausted} = run(context, config, options(context))
    before_recheck = Receipt.read(context.receipt)
    assert before_recheck["rework_count"] == 1
    assert calls(context, :reviewer) == []
    original_log = File.read!(context.receipt <> ".evidence/round-2/check-1.log")
    # Historical receipts can lack issue_scope; the completed recheck's audit proves it.
    File.write!(context.receipt, Jason.encode!(Map.delete(before_recheck, "issue_scope")))
    recheck = resume_context(context, options(context, review: fn _ -> false end))
    recheck = %{recheck | settings: %{checks: [["true"]], check_timeout_ms: 10_000, max_rework: 1}}
    assert {:error, :mvp_rework_exhausted} = Executor.recheck(recheck, digest(File.read!(context.receipt)), authorization("legacy-recheck"))
    rejected = Receipt.read(context.receipt)
    review_path = context.receipt <> ".evidence/operator-rechecks/legacy-recheck/review.json"
    assert List.last(rejected["rounds"])["review_path"] == review_path
    rejected_bytes = File.read!(review_path)
    assert rejected["candidate_sha"] == before_recheck["candidate_sha"]
    assert rejected["rework_count"] == 1
    assert is_nil(rejected["check_failure"])
    resume = resume_context(context, options(context))
    auth = authorization("adopt-operator-review") |> Map.put("predecessor", "legacy-recheck")
    assert {:ok, @url} = Executor.recover(resume, digest(File.read!(context.receipt)), auth)
    assert File.read!(review_path) == rejected_bytes
    assert File.read!(context.receipt <> ".evidence/round-2/check-1.log") == original_log
    assert Receipt.read(context.receipt)["base_sha"] == before_recheck["base_sha"]
    assert length(calls(context, :publish)) == 1
    assert List.last(calls(context, :reviewer)).sha != rejected["candidate_sha"]
  end

  test "adoption requires enabled recovery, unchanged scope and a confirmed comment" do
    {context, raw, old_data} = exhausted_review!()
    resume = resume_context(context, options(context))
    disabled = put_in(resume, [:settings, :recovery, :enabled], false)
    assert {:error, :mvp_recovery_not_enabled} = Executor.recover(disabled, digest(raw), authorization("disabled"))
    changed_scope = %{resume | issue: %{resume.issue | description: "Unapproved broader requirement"}}
    assert {:error, :mvp_recovery_scope_mismatch} = Executor.recover(changed_scope, digest(raw), authorization("scope"))

    File.write!(context.receipt, Jason.encode!(Map.delete(old_data, "issue_scope")))
    assert {:error, :mvp_recovery_scope_mismatch} = Executor.recover(resume, digest(File.read!(context.receipt)), authorization("missing-scope"))
    File.write!(context.receipt, raw)
    pending = update_in(old_data, ["rounds"], fn rounds -> List.update_at(rounds, -1, &put_in(&1, ["comment", "id"], nil)) end)
    File.write!(context.receipt, Jason.encode!(pending))
    assert {:error, :mvp_recovery_evidence_mismatch} = Executor.recover(resume, digest(File.read!(context.receipt)), authorization("unconfirmed-comment"))
    assert calls(context, :diagnosis) == []
    refute File.exists?(context.receipt <> ".evidence/operator-rechecks")
  end

  test "matching review bytes outside the approved evidence path cannot authorize adoption" do
    {context, _raw, data} = exhausted_review!()
    resume = resume_context(context, options(context))
    last = List.last(data["rounds"])
    unbound_path = Path.join(context.root, "copied-review.json")
    File.cp!(last["review_path"], unbound_path)
    forged = update_in(data, ["rounds"], fn rounds -> List.update_at(rounds, -1, &Map.put(&1, "review_path", unbound_path)) end)
    File.write!(context.receipt, Jason.encode!(forged))

    assert {:error, :mvp_recovery_evidence_mismatch} = Executor.recover(resume, digest(File.read!(context.receipt)), authorization("outside-review"))
    assert calls(context, :diagnosis) == []
    assert calls(context, :publish) == []
  end

  test "an exhausted legacy check resumes repair with its original failure evidence preserved" do
    {context, raw, old_data} = exhausted_check!()
    failure = old_data["check_failure"]
    original_log = File.read!(failure["log_path"])
    original_json = File.read!(Path.rootname(failure["log_path"]) <> ".json")
    resume = resume_context(context, options(context))
    resume = %{resume | settings: settings([numeric_check(3)])}

    assert {:ok, @url} = Executor.recover(resume, digest(raw), authorization("adopt-check"))
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 2
    assert data["recovery"]["adopted_rework_count"] == 1
    assert data["recovery"]["adopted_agent_attempts"] == 4
    assert hd(calls(context, :diagnosis)).sha == old_data["candidate_sha"]
    assert hd(calls(context, :diagnosis)).prompt =~ failure["log_path"]
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "3"
    assert File.read!(failure["log_path"]) == original_log
    assert File.read!(Path.rootname(failure["log_path"]) <> ".json") == original_json
    assert hd(data["rounds"]) == hd(old_data["rounds"])
    assert Enum.at(data["rounds"], 1)["check_failure"] == failure
    assert data["base_sha"] == old_data["base_sha"]
    assert length(calls(context, :coder)) == 3
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :publish)) == 1
  end

  test "a changed check report cannot authorize recovery of a legacy check failure" do
    {context, raw, old_data} = exhausted_check!()
    failure = old_data["check_failure"]
    report = Path.rootname(failure["log_path"]) <> ".json"
    File.write!(report, Jason.encode!(Map.put(failure, "exit_status", 0)))
    resume = resume_context(context, options(context))

    assert {:error, :mvp_recovery_evidence_mismatch} = Executor.recover(resume, digest(raw), authorization("changed-check"))
    assert File.read!(context.receipt) == raw
    assert calls(context, :diagnosis) == []
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
    refute File.exists?(context.receipt <> ".evidence/operator-rechecks")
  end

  test "uncertain comments without a unique confirmed match remain pending and are never posted twice" do
    for reconciliation <- [:zero, :multiple, :unavailable] do
      context = context!()

      request = fn
        "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _ ->
          record(context, :comment, body)
          {:error, :connection_closed_after_write}

        "GET", "/repos/owner/repo/issues/42/comments", %{"per_page" => 100, "page" => 1}, nil, _ ->
          record(context, :comment_read, %{})
          [body] = calls(context, :comment)

          case reconciliation do
            :zero -> {:ok, %{status: 200, body: []}}
            :multiple -> {:ok, %{status: 200, body: [%{"id" => 71, "body" => body["body"]}, %{"id" => 72, "body" => body["body"]}]}}
            :unavailable -> {:error, :github_unavailable}
          end
      end

      opts = options(context, review: fn _ -> false end) |> Keyword.put(:request_fun, request)
      assert {:error, :mvp_comment_uncertain} = run(context, settings([["true"]]), opts)
      assert length(calls(context, :comment)) == 1
      assert length(calls(context, :comment_read)) == 1
      assert length(calls(context, :coder)) == 1
      assert length(calls(context, :reviewer)) == 1
      assert calls(context, :diagnosis) == []
      assert calls(context, :publish) == []
      data = Receipt.read(context.receipt)
      assert data["status"] == "comment_pending"
      assert hd(data["rounds"])["comment"]["id"] == nil
      assert hd(data["rounds"])["comment"]["body"] == hd(calls(context, :comment))["body"]
    end
  end

  test "a legacy receipt without scope cannot inherit authorization from an invalid predecessor" do
    {context, _raw, old_data} = exhausted_review!()
    resume = resume_context(context, options(context))

    for previous <- ["../outside", "missing-audit"] do
      data = old_data |> Map.delete("issue_scope") |> Map.put("operator_recheck", previous)
      raw = Jason.encode!(data)
      File.write!(context.receipt, raw)
      assert {:error, :mvp_recovery_scope_mismatch} = Executor.recover(resume, digest(raw), authorization("unbound-scope"))
      assert File.read!(context.receipt) == raw
    end

    assert calls(context, :diagnosis) == []
    assert calls(context, :publish) == []
    refute File.exists?(context.receipt <> ".evidence/operator-rechecks")
  end

  test "rootless environment failure retries every frozen check on the same candidate without spending rework" do
    context = context!()
    checks = [["python3", "scripts/check_candidate.py"], ["python3", "scripts/check_baseline.py"]]
    outcomes = [:passed, :environment, :passed, :passed]
    policy = %{"max_rework" => 1, "stage_attempts" => 2}
    assert {:ok, @url} = rootless_run(context, outcomes, policy, checks: checks)

    [first, failed, retry, retried_baseline] = calls(context, :formal_check)
    assert first.sha == retry.sha
    assert Enum.uniq(Enum.map(calls(context, :formal_check), & &1.sha)) == [first.sha]
    assert first.started_at == retry.started_at
    assert first.agent_attempts == retry.agent_attempts
    assert first.command == retry.command
    assert failed.command == retried_baseline.command
    assert length(calls(context, :coder)) == 1
    assert calls(context, :diagnosis) == []
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :publish)) == 1
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 0
    assert data["stage_retries"] == 1
    assert data["recovery"]["agent_attempts"] == 2
    assert length(data["rounds"]) == 1
    assert data["candidate_sha"] == first.sha
    evidence = hd(data["rounds"])["evidence"]
    failed = Path.join(evidence, "check-2.json") |> File.read!() |> Jason.decode!()
    assert failed["category"] == "environment"
    assert failed["candidate_sha"] == first.sha
    assert failed["error"] =~ "sandbox_environment_failure"
    assert File.regular?(Path.join(evidence, "check-attempt-2/check-1.json"))
    assert File.regular?(Path.join(evidence, "check-attempt-2/check-2.json"))
    assert File.read!(Path.join(context.receipt <> ".evidence/baseline", "source.txt")) == "base source\n"
  end

  test "rootless environment stage retries stop at their own bound without dispatching another coder" do
    context = context!()

    assert {:error, :mvp_recovery_stage_exhausted} =
             rootless_run(context, [:environment, :environment, :passed], %{"max_rework" => 1, "stage_attempts" => 2})

    [first, retry] = calls(context, :formal_check)
    assert first.sha == retry.sha
    assert length(calls(context, :coder)) == 1
    assert calls(context, :diagnosis) == []
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
    data = Receipt.read(context.receipt)
    assert data["status"] == "blocked"
    assert data["reason"] == ":mvp_recovery_stage_exhausted"
    assert data["rework_count"] == 0
    assert data["stage_retries"] == 1
    assert data["recovery"]["agent_attempts"] == 1
    assert data["check_failure"]["category"] == "environment"
    refute File.exists?(context.receipt <> ".evidence/round-1/check-attempt-3")
  end

  test "rootless export and integrity failures preserve evidence and stop before diagnosis or recoding" do
    for {outcome, category, reason} <- [
          {:export, "export", "sandbox_export_incomplete"},
          {:cleanup, "integrity", "sandbox_cleanup_incomplete"},
          {:exit_mismatch, "integrity", "sandbox_check_exit_mismatch"}
        ] do
      context = context!()
      assert {:error, {:mvp_trusted_failure_requires_attention, failure}} = rootless_run(context, [outcome])
      assert failure["category"] == category
      assert failure["reason"] == reason
      assert failure["retryable"] == false
      assert length(calls(context, :formal_check)) == 1
      assert length(calls(context, :coder)) == 1
      assert calls(context, :diagnosis) == []
      assert calls(context, :reviewer) == []
      assert calls(context, :publish) == []
      data = Receipt.read(context.receipt)
      assert data["status"] == "blocked"
      assert data["rework_count"] == 0
      assert data["recovery"]["agent_attempts"] == 1
      assert data["check_failure"]["candidate_sha"] == data["candidate_sha"]
      assert File.regular?(data["check_failure"]["log_path"])
      assert File.regular?(Path.rootname(data["check_failure"]["log_path"]) <> ".json")
      refute File.exists?(context.receipt <> ".evidence/round-1/check-attempt-2")
    end
  end

  test "rootless unknown failures permit only read-only diagnosis and cannot be downgraded to code repair" do
    context = context!()
    assert {:error, :mvp_trusted_failure_requires_attention} = rootless_run(context, [:unknown], %{}, diagnosis: "repair_code")

    [diagnosis] = calls(context, :diagnosis)
    assert diagnosis.read_only
    assert diagnosis.prompt =~ "Do not modify files"
    assert diagnosis.prompt =~ "\"category\":\"unknown\""
    assert diagnosis.sha == hd(calls(context, :formal_check)).sha
    assert length(calls(context, :coder)) == 1
    assert calls(context, :reviewer) == []
    assert calls(context, :publish) == []
    data = Receipt.read(context.receipt)
    assert data["status"] == "blocked"
    assert data["check_failure"]["category"] == "unknown"
    assert data["recovery"]["agent_attempts"] == 2
    assert data["rework_count"] == 0
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "1"
  end

  test "rootless unknown failure diagnosis can repeat trusted checks without changing the candidate" do
    context = context!()
    assert {:ok, @url} = rootless_run(context, [:unknown, :passed], %{}, diagnosis: "retry_stage")

    [first, retry] = calls(context, :formal_check)
    assert first.sha == retry.sha
    assert first.command == retry.command
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :diagnosis)) == 1
    assert hd(calls(context, :diagnosis)).read_only
    assert length(calls(context, :reviewer)) == 1
    assert hd(calls(context, :reviewer)).sha == first.sha
    assert Receipt.read(context.receipt)["rework_count"] == 0
    assert Receipt.read(context.receipt)["stage_retries"] == 1
    assert Receipt.read(context.receipt)["recovery"]["agent_attempts"] == 3
  end

  test "finish preserves external waiting when enabled profiles omit the blocked acceptance" do
    context = context!()
    profiles = %{"another acceptance" => %{"kind" => "linux", "runner_sha256" => String.duplicate("a", 64), "timeout_ms" => 60_000}}
    behavior = [external_review: true, profiles: profiles]
    assert {:error, {:mvp_awaiting_external, handoff_id}} = rootless_run(context, [:passed], %{}, behavior)
    assert_external_wait_preserved(context, handoff_id)
    assert Receipt.read(context.receipt)["execution_sandbox"]["acceptance_profiles"] == profiles
  end

  test "finish with no acceptance profiles leaves the same reviewed candidate awaiting external evidence" do
    context = context!()
    assert {:error, {:mvp_awaiting_external, handoff_id}} = rootless_run(context, [:passed], %{}, external_review: true)
    assert_external_wait_preserved(context, handoff_id)
    assert Receipt.read(context.receipt)["execution_sandbox"]["acceptance_profiles"] == %{}
  end

  defp assert_external_wait_preserved(context, handoff_id) do
    data = Receipt.read(context.receipt)
    assert data["status"] == "awaiting_external"
    assert data["external_handoff"]["id"] == handoff_id
    assert data["external_handoff"]["candidate_sha"] == data["candidate_sha"]
    assert data["candidate_sha"] == hd(calls(context, :formal_check)).sha
    assert data["rework_count"] == 0
    assert data["recovery"]["agent_attempts"] == 2
    assert length(calls(context, :coder)) == 1
    assert length(calls(context, :reviewer)) == 1
    assert calls(context, :diagnosis) == []
    assert calls(context, :publish) == []
    assert length(calls(context, :formal_check)) == 1
    refute File.exists?(context.receipt <> ".evidence/acceptance-jobs")
    assert File.regular?(List.last(data["rounds"])["review_path"])
  end

  defp rootless_run(context, outcomes, policy \\ %{}, behavior \\ []) do
    previous = Map.new(~w(GH12_CODER_KEY GH12_REVIEWER_KEY), &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, &restore_environment/1) end)
    for name <- Map.keys(previous), do: System.put_env(name, "synthetic-recovery-account")
    trusted = Path.join(context.root, "trusted")
    File.mkdir_p!(Path.join(trusted, "scripts"))
    File.write!(Path.join(trusted, "scripts/execution_sandbox.sh"), "printf '%s' '{\"status\":\"ready\",\"backend\":\"rootless\"}'\n")

    {:ok, sandbox} =
      ExecutionSandbox.settings(%{
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
        "auth_home" => Path.join(context.root, "auth"),
        "acceptance_profiles" => Keyword.get(behavior, :profiles, %{})
      })

    authority = ServiceFixture.settings(Path.join(context.root, "authority"))
    checks = Keyword.get(behavior, :checks, [["python3", "scripts/check_candidate.py"]])
    config = Map.merge(authority, settings(checks, policy)) |> Map.put(:sandbox, sandbox) |> Map.put(:model_command, sandbox["codex"] <> " app-server")

    registry =
      Enum.reduce([{:coder, "coding"}, {:reviewer, "reviewing"}], config.model_services, fn {role, id}, registry ->
        {:ok, service} = ModelServices.snapshot(%{config | model_services: registry}, id, role, "fixture")
        {:ok, registry} = ModelCatalog.attest(registry, service, ServiceFixture.proof(role))
        registry
      end)

    config = %{config | model_services: registry}
    ServiceFixture.write_authority!(config)

    services =
      Map.new([{:coder, "coding"}, {:reviewer, "reviewing"}], fn {role, id} ->
        {:ok, service} = ModelServices.snapshot(config, id, role, "fixture")
        {Atom.to_string(role), service}
      end)

    selected = %{coder: "gpt-test", reviewer: "gpt-test", services: services}
    opts = options(context, behavior)
    agent = rootless_agent(context, opts[:agent])

    command = fn argv, workspace, _timeout, log_path ->
      scratch = argv |> Enum.drop_while(&(&1 != "--scratch-root")) |> Enum.at(1)
      count = length(calls(context, :formal_check))
      outcome = Enum.fetch!(outcomes, count)
      sha = Commands.git!(["rev-parse", "HEAD"], workspace)
      data = Receipt.read(context.receipt)
      binding = %{sha: sha, command: Enum.drop_while(argv, &(&1 != "--"))}
      resources = %{started_at: data["recovery"]["started_at"], agent_attempts: data["recovery"]["agent_attempts"]}
      record(context, :formal_check, Map.merge(binding, resources))
      status = if outcome in [:environment, :unknown, :exit_mismatch], do: 1, else: 0
      sandbox_result!(scratch, outcome, status)
      evidence = Path.join(scratch, "export/.check-evidence")
      File.mkdir_p!(evidence)
      category = if outcome == :environment, do: "environment", else: "unknown"
      File.write!(Path.join(evidence, "result.json"), Jason.encode!(%{"identity" => %{"candidate_sha" => sha}, "failure_category" => category, "outcome" => status}))
      File.write!(log_path, "retained #{outcome} check evidence for #{sha}\n")
      {:ok, status}
    end

    opts = opts |> Keyword.put(:sandbox_agent_run, agent) |> Keyword.put(:sandbox_command_run, command) |> Keyword.put(:sandbox_cleanup_timeout_ms, 1)
    Executor.run(context.workspace, context.issue, config, selected, context.receipt, opts)
  end

  defp restore_environment({name, nil}), do: System.delete_env(name)
  defp restore_environment({name, value}), do: System.put_env(name, value)

  defp rootless_agent(context, original) do
    fn workspace, prompt, issue, opts ->
      scratch = Path.join(Path.dirname(opts[:execution_environment].codex_home), "sandbox")
      sandbox_result!(scratch, :passed, 0)

      if agent_role(opts) == :coder,
        do: isolated_coder(context, workspace, prompt, opts, scratch),
        else: original.(workspace, prompt, issue, opts)
    end
  end

  defp isolated_coder(context, workspace, prompt, opts, scratch) do
    sha = Commands.git!(["rev-parse", "HEAD"], workspace)
    record(context, :coder, %{sha: sha, model: opts[:model], prompt: prompt, read_only: opts[:read_only]})
    export = Path.join(scratch, "export")
    File.mkdir_p!(export)
    for name <- File.ls!(workspace), name != ".git", do: File.cp_r!(Path.join(workspace, name), Path.join(export, name))
    File.write!(Path.join(export, "candidate.txt"), "1")
    opts[:on_message].(%{usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}})
    {:ok, %{output_text: "Implemented isolated candidate"}}
  end

  defp sandbox_result!(scratch, outcome, status) do
    File.mkdir_p!(scratch)

    File.write!(
      Path.join(scratch, "result.json"),
      Jason.encode!(%{
        "cleanup_complete" => outcome != :cleanup,
        "export_complete" => outcome != :export,
        "scratch_root" => scratch,
        "exit_status" => if(outcome == :exit_mismatch, do: 0, else: status)
      })
    )
  end

  defp external_review do
    Map.put(review(false), "blockers", [
      %{
        "acceptance" => "Meet the checked candidate requirement",
        "kind" => "external_condition",
        "reason" => "The required signed external proof is unavailable",
        "required_evidence" => "Signed proof bound to this candidate SHA",
        "handoff" => "Authorized operator supplies the signed proof"
      }
    ])
  end

  defp gitlab_context! do
    context = context!()

    issue = %{
      context.issue
      | identifier: "GL-42",
        state: "opened",
        native_ref: %{"kind" => "gitlab", "repo" => "owner/repo", "project_path" => "owner/repo", "api_url" => "https://gitlab.example/api/v4", "iid" => 42}
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(context.root, "gitlab-state")}, issue)
    %{context | issue: issue, receipt: receipt}
  end

  defp gitlab_options(context, behavior) do
    tracker = %{kind: "gitlab", provider: %{"api_url" => "https://gitlab.example/api/v4", "project_path" => "owner/repo", "api_key" => "synthetic"}}
    original = options(context, behavior)
    agent = original[:agent]

    request = fn method, path, _query, body, _ ->
      case {method, path} do
        {"GET", "/projects/owner%2Frepo"} ->
          {:ok, %{status: 200, body: %{"id" => 3, "path_with_namespace" => "owner/repo", "default_branch" => "main"}}}

        {"GET", "/projects/owner%2Frepo/issues/42"} ->
          {:ok, %{status: 200, body: %{"state" => "opened", "labels" => ["ready"]}}}

        {"POST", "/projects/owner%2Frepo/issues/42/notes"} ->
          record(context, :comment, body)
          {:ok, %{status: 201, body: Map.put(body, "id", length(calls(context, :comment)))}}

        {"GET", "/projects/owner%2Frepo/merge_requests"} ->
          {:ok, %{status: 200, body: calls(context, :mr_created)}}

        {"POST", "/projects/owner%2Frepo/merge_requests"} ->
          mr = %{
            "iid" => 9,
            "source_project_id" => 3,
            "target_project_id" => 3,
            "source_branch" => body["source_branch"],
            "target_branch" => body["target_branch"],
            "sha" => Commands.git!(["rev-parse", "HEAD"], context.workspace),
            "state" => "opened",
            "draft" => true,
            "web_url" => "https://gitlab.example/owner/repo/-/merge_requests/9",
            "description" => body["description"]
          }

          record(context, :mr_created, mr)
          {:ok, %{status: 201, body: mr}}
      end
    end

    original
    |> Keyword.delete(:publish)
    |> Keyword.put(:tracker_settings, tracker)
    |> Keyword.put(:ready_label, "ready")
    |> Keyword.put(:request_fun, request)
    |> Keyword.put(:agent, fn workspace, prompt, issue, opts ->
      result = agent.(workspace, prompt, issue, opts)

      if agent_role(opts) == :reviewer and Keyword.get(behavior, :external_review, false) do
        {:ok, response} = result
        review = Jason.decode!(response.output_text)
        review = Map.update!(review, "blockers", &verification_blockers/1)
        {:ok, %{response | output_text: Jason.encode!(review)}}
      else
        result
      end
    end)
  end

  defp verification_blockers(blockers), do: Enum.map(blockers, &Map.put(&1, "external_kind", "verification"))

  defp context! do
    root = Path.join(System.tmp_dir!(), "recovery-executor-#{System.unique_integer([:positive])}")
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
      title: "Repair candidate",
      description: "Meet the checked candidate requirement.",
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

  defp settings(checks, overrides \\ %{}) do
    {:ok, policy} = Recovery.settings(Map.merge(%{"enabled" => true}, overrides))
    %{checks: checks, check_timeout_ms: 10_000, max_rework: 0, recovery: policy}
  end

  defp run(context, settings, opts), do: Executor.run(context.workspace, context.issue, settings, models(), context.receipt, opts)
  defp models, do: %{coder: "coder-model", reviewer: "reviewer-model"}

  defp options(context, behavior \\ []) do
    [
      repository: fn _, _ -> {:ok, context.repository} end,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}},
      agent: fn workspace, prompt, _issue, opts ->
        role = agent_role(opts)
        sha = Commands.git!(["rev-parse", "HEAD"], workspace)
        record(context, role, %{sha: sha, model: opts[:model], prompt: prompt, read_only: opts[:read_only]})
        opts[:on_message].(%{usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}})

        case role do
          :coder ->
            path = Path.join(workspace, "candidate.txt")
            number = if File.exists?(path), do: String.to_integer(File.read!(path)) + 1, else: 1

            unless Keyword.get(behavior, :skip_first_coder, false) and length(calls(context, :coder)) == 1 do
              File.write!(path, Integer.to_string(number))
            end

            {:ok, %{output_text: "Implemented candidate #{number}"}}

          :reviewer ->
            approved = Keyword.get(behavior, :review, fn _ -> true end).(length(calls(context, :reviewer)))
            result = if Keyword.get(behavior, :external_review, false), do: external_review(), else: review(approved)
            {:ok, %{output_text: Jason.encode!(result)}}

          :diagnosis ->
            diagnosis = %{"action" => Keyword.get(behavior, :diagnosis, "repair_code"), "summary" => "Investigate technical failure", "steps" => ["Read logs and fix the underlying cause"]}
            {:ok, %{output_text: Jason.encode!(diagnosis)}}
        end
      end,
      publish: fn _, _, _, _, sha, _, _ ->
        record(context, :publish, %{sha: sha})
        {:ok, @url}
      end,
      request_fun: fn "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _ ->
        record(context, :comment, body)
        {:ok, %{status: 201, body: %{"id" => length(calls(context, :comment)), "body" => body["body"]}}}
      end
    ]
  end

  defp agent_role(opts) do
    required = Keyword.get(opts, :output_schema, %{}) |> Map.get("required", [])

    cond do
      "action" in required -> :diagnosis
      "approved" in required -> :reviewer
      true -> :coder
    end
  end

  defp review(approved) do
    %{
      "approved" => approved,
      "summary" => if(approved, do: "Checked candidate meets acceptance", else: "Candidate requires a correction"),
      "criteria" => [
        %{
          "acceptance" => "Meet the checked candidate requirement",
          "tests" => ["controller candidate check"],
          "assertion_strength" => "Asserts the candidate value",
          "failure_sensitivity" => "A wrong value fails",
          "adequate" => approved
        }
      ]
    }
  end

  defp record(context, role, value), do: Process.put({context.key, role}, calls(context, role) ++ [value])
  defp calls(context, role), do: Process.get({context.key, role}, [])

  defp numeric_check(target) do
    ["python3", "-c", "import pathlib,sys; n=int(pathlib.Path(sys.argv[1]).read_text()); print(n); sys.exit(0 if n>=int(sys.argv[2]) else 10)", "{workspace}/candidate.txt", Integer.to_string(target)]
  end

  defp trace_check(trace) do
    ["python3", "-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); f=open(sys.argv[2],'a'); f.write(p.read_text()+'\\n'); f.close()", "{workspace}/candidate.txt", trace]
  end

  defp exhausted_review! do
    context = context!()
    config = %{checks: [["true"]], check_timeout_ms: 10_000, max_rework: 1}
    assert {:error, :mvp_rework_exhausted} = run(context, config, options(context, review: fn _ -> false end))
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 1
    assert length(data["rounds"]) == 2
    assert length(calls(context, :comment)) == 2
    {context, File.read!(context.receipt), data}
  end

  defp exhausted_check! do
    context = context!()
    config = %{checks: [numeric_check(3)], check_timeout_ms: 10_000, max_rework: 1}
    assert {:error, :mvp_rework_exhausted} = run(context, config, options(context))
    data = Receipt.read(context.receipt)
    assert data["rework_count"] == 1
    assert length(data["rounds"]) == 2
    assert data["check_failure"]["exit_status"] == 10
    assert calls(context, :reviewer) == []
    {context, File.read!(context.receipt), data}
  end

  defp resume_context(context, opts) do
    data = Receipt.read(context.receipt)
    evidence = context.receipt <> ".evidence"
    baseline = Path.join(evidence, "baseline")

    baseline_digest =
      Path.wildcard(Path.join(baseline, "**/*"), match_dot: true)
      |> Enum.map(fn path -> {Path.relative_to(path, baseline), :crypto.hash(:sha256, File.read!(path))} end)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Map.merge(context, %{
      settings: settings([["true"]]),
      models: models(),
      opts: opts,
      branch: data["branch"],
      evidence: evidence,
      base: data["base_sha"],
      baseline_digest: baseline_digest,
      limit: 1,
      metadata: Map.new([".git/config", ".git/info/attributes", ".git/info/exclude"], &{&1, File.read(Path.join(context.workspace, &1))})
    })
  end

  defp old_evidence(data) do
    for round <- data["rounds"], name <- ["check-1.log", "check-1.json", "review.json"], into: %{} do
      path = Path.join(round["evidence"], name)
      {path, File.read!(path)}
    end
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp authorization(id) do
    %{
      "id" => id,
      "authorization" => "Explicit test authorization for this task only",
      "runtime_version" => String.duplicate("a", 40),
      "command" => ["test", "recover"],
      "diagnostic" => "Preserve the candidate and repair the rejected acceptance",
      "legacy_closures" => [],
      "predecessor" => nil
    }
  end
end
