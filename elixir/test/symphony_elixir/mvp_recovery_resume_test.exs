defmodule SymphonyElixir.Mvp.RecoveryResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Commands, ExecutionSandbox, Executor, Receipt, Recovery, ReviewProtocol}

  @url "https://github.com/owner/repo/pull/42"

  for parameters <- [nil, %{"reasoning_effort" => nil}] do
    @parameters parameters
    test "audited recovery keeps full role services after defaults change and rejects service drift at every entry with #{inspect(parameters)}" do
      alias SymphonyElixir.ModelServicesFixture, as: Fixture
      alias SymphonyElixir.Mvp.{Intake, ModelCatalog, ModelServices}
      System.put_env("GH12_CODER_KEY", "recovery-synthetic-coder")
      System.put_env("GH12_REVIEWER_KEY", "recovery-synthetic-reviewer")

      on_exit(fn ->
        System.delete_env("GH12_CODER_KEY")
        System.delete_env("GH12_REVIEWER_KEY")
      end)

      context = context!()
      service_settings = Fixture.settings(Path.join(context.root, "state"), @parameters)
      settings = Map.merge(settings(), service_settings)
      {:ok, selected} = Intake.resolve_comments([], service_settings)
      initial = options(context, :dirty_repair)

      assert {:error, :mvp_recovery_resource_exhausted} =
               Executor.run(context.workspace, context.issue, settings, selected, context.receipt, initial)

      prepare_gh5_history!(context, settings)
      proposed = put_in(settings.model_services, ["defaults", "coder"], "reviewing")
      {:ok, new_default} = ModelServices.snapshot(%{settings | model_services: proposed}, "reviewing", :coder, "fixture")
      {:ok, proposed} = ModelCatalog.attest(proposed, new_default, Fixture.proof(:coder))
      assert {:ok, _} = ModelServices.save(ModelServices.path(settings), settings.model_services, 0, proposed)
      {resume, auth} = resume_inputs!(context, settings, "role-frozen")
      original = resume.opts[:agent]

      agent = fn workspace, prompt, issue, opts ->
        role = if agent_role(opts) == :reviewer, do: "reviewer", else: "coder"
        assert opts[:model_service] == selected.services[role]
        original.(workspace, prompt, issue, opts)
      end

      resume = %{resume | models: Map.take(selected, [:coder, :reviewer]), services: selected.services, opts: Keyword.put(resume.opts, :agent, agent)}
      drifted = put_in(resume, [:services, "coder", "connection", "base_url"], "https://other.example/v1")
      raw = File.read!(context.receipt)
      digest = digest(raw)

      entrypoints = [
        fn -> Executor.resume_recovery(drifted, digest, auth) end,
        fn -> Executor.recover(drifted, digest, auth) end,
        fn -> Executor.resume_review(drifted, digest, auth) end,
        fn -> Executor.resume_interrupted(drifted, digest, auth) end,
        fn -> Executor.resume_external(drifted, digest, auth) end,
        fn -> Executor.recheck(drifted, digest, auth) end,
        fn -> Executor.resume_checks(drifted, digest) end,
        fn -> Executor.extend_rework(drifted, digest, 5) end
      ]

      for entry <- entrypoints do
        assert {:error, :mvp_resume_binding_mismatch} = entry.()
        assert File.read!(context.receipt) == raw
      end

      assert {:ok, @url} = Executor.resume_recovery(resume, digest, auth)
      assert Receipt.read(context.receipt)["services"] == selected.services
      assert File.read!(Path.join(context.workspace, "candidate.txt")) == "completed from partial"
    end
  end

  test "audited recovery refuses embedded revocation reloaded after its context was prepared" do
    alias SymphonyElixir.ModelServicesFixture, as: Fixture
    alias SymphonyElixir.Mvp.Intake
    System.put_env("GH12_CODER_KEY", "recovery-synthetic-coder")
    System.put_env("GH12_REVIEWER_KEY", "recovery-synthetic-reviewer")

    on_exit(fn ->
      System.delete_env("GH12_CODER_KEY")
      System.delete_env("GH12_REVIEWER_KEY")
    end)

    context = context!()
    settings = Map.merge(settings(), Fixture.settings(Path.join(context.root, "state")))
    Workflow.set_workflow_file_path(settings.workflow_path)
    assert :ok = WorkflowStore.force_reload()
    {:ok, selected} = Intake.resolve_comments([], settings)

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.run(context.workspace, context.issue, settings, selected, context.receipt, options(context, :dirty_repair))

    prepare_gh5_history!(context, settings)
    {resume, auth} = resume_inputs!(context, settings, "embedded-revoked")

    opts =
      resume.opts
      |> Keyword.put(:agent, fn _, _, _, _ -> flunk("revoked model must not start") end)
      |> Keyword.put(:publish, fn _, _, _, _, _, _, _ -> flunk("must not publish") end)

    resume = %{resume | models: Map.take(selected, [:coder, :reviewer]), services: selected.services, opts: opts}
    revoked = put_in(settings.model_services, ["catalog", "coding", "models", "gpt-test", "disabled"], true)
    Fixture.write_authority!(%{settings | model_services: revoked})
    assert :ok = WorkflowStore.force_reload()
    assert {:error, :model_disabled} = Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)
    data = Receipt.read(context.receipt)
    assert data["status"] == "blocked"
    assert data["services"] == selected.services
  end

  test "audited resume continues a synthetic GH5-shaped dirty coder receipt and adds only wall time" do
    context = context!()
    sandbox = sandbox_profile!(context)
    checks = List.duplicate(["python3", sandbox.script], 10)
    settings = settings(checks)
    initial_opts = options(context, :dirty_repair)

    assert {:error, :mvp_recovery_resource_exhausted} = run(context, settings, initial_opts)
    prepare_gh5_history!(context, settings)
    before = Receipt.read(context.receipt)
    assert before["status"] == "blocked"
    assert before["reason"] == ":mvp_recovery_resource_exhausted"
    assert before["rework_count"] == 11
    assert length(before["rounds"]) == 12
    assert is_nil(List.last(before["rounds"])["candidate_sha"])
    rejected_round = Enum.at(before["rounds"], 8)
    receipt_raw = File.read!(context.receipt)
    assert rejected_round["review"]["approved"] == false
    assert rejected_round["comment"]["id"] > 0
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "partial"

    {:ok, start, _} = DateTime.from_iso8601(before["recovery"]["started_at"])
    wall_elapsed = before["recovery"]["policy"]["max_elapsed_ms"]
    expired_now = DateTime.to_unix(start, :millisecond) + wall_elapsed + 1_000
    resume_opts = options(context, :dirty_repair) |> sandbox_callbacks(context) |> Keyword.put(:now_ms, fn -> expired_now end)
    resume_settings = %{settings | sandbox: sandbox.settings}
    resume = resume_context(context, resume_settings, resume_opts)
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    effective_sandbox = json_map(sandbox.settings)
    sandbox_change = %{"from" => %{"enabled" => false}, "to" => effective_sandbox}

    resume_authorization =
      authorization("dirty-resume", workspace_sha)
      |> Map.put("execution_sandbox_change", sandbox_change)

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), resume_authorization)

    after_data = Receipt.read(context.receipt)
    operation = Path.join([context.receipt <> ".evidence", "operator-rechecks", "dirty-resume"])
    audit = Path.join(operation, "authorization.json") |> File.read!() |> Jason.decode!()
    completion = Path.join(operation, "completion.json") |> File.read!() |> Jason.decode!()
    original_policy = before["recovery"]["policy"]
    effective_policy = after_data["recovery"]["policy"]

    assert audit["receipt_sha256"] == digest(receipt_raw)
    assert audit["workspace_digest"] == workspace_sha
    assert audit["wall_budget_extension_ms"] == 1_000_000
    assert audit["original_execution_sandbox"] == %{"enabled" => false}
    assert audit["effective_execution_sandbox"] == effective_sandbox
    assert audit["execution_sandbox_change"] == sandbox_change
    assert audit["original_recovery_policy"] == original_policy
    assert audit["effective_recovery_policy"]["max_elapsed_ms"] == original_policy["max_elapsed_ms"] + 1_000_000
    assert effective_policy["max_elapsed_ms"] == original_policy["max_elapsed_ms"] + 1_000_000
    assert Map.drop(effective_policy, ["max_elapsed_ms"]) == Map.drop(original_policy, ["max_elapsed_ms"])
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_data["execution_sandbox"] == effective_sandbox
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 2
    assert after_data["rework_count"] == before["rework_count"]
    assert length(after_data["rounds"]) == length(before["rounds"])
    assert Enum.take(after_data["recovery"]["events"], length(before["recovery"]["events"])) == before["recovery"]["events"]
    assert Enum.any?(after_data["recovery"]["events"], &(&1["kind"] == "operator_wall_budget_extension"))
    assert completion["id"] == "dirty-resume"
    assert Enum.at(after_data["rounds"], 8)["review"]["approved"] == false
    assert Enum.at(after_data["rounds"], 8)["comment"]["id"] == rejected_round["comment"]["id"]
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "completed from partial"

    [resumed_reviewer] = calls(context, :reviewer)
    refute resumed_reviewer.sha == rejected_round["candidate_sha"]
    assert length(calls(context, :coder)) == 2
    resumed_prompt = Enum.at(calls(context, :coder), 1).prompt
    assert resumed_prompt =~ "review_rejection"
    assert resumed_prompt =~ "operator_diagnostic"
    assert resumed_prompt =~ "Most recent check failure"
    resumed_coder = Enum.at(calls(context, :coder), 1)
    assert resumed_coder.existing == "partial"
    assert resumed_coder.sha == before["candidate_sha"]
    assert length(calls(context, :publish)) == 1
    assert Enum.map(calls(context, :sandbox_agent), & &1.role) == [:coder, :reviewer]
    assert length(calls(context, :sandbox_check)) == 10
  end

  test "resume requires the exact dirty-workspace digest, an explicit bounded extension and an unchanged sandbox" do
    context = context!()
    settings = settings()
    assert {:error, :mvp_recovery_resource_exhausted} = run(context, settings, options(context, :dirty_repair))
    data = Receipt.read(context.receipt)
    raw = File.read!(context.receipt)
    {:ok, start, _} = DateTime.from_iso8601(data["recovery"]["started_at"])
    expired_now = DateTime.to_unix(start, :millisecond) + data["recovery"]["policy"]["max_elapsed_ms"] + 1_000
    {:ok, initial_workspace_sha} = Executor.workspace_digest(context.workspace)
    untracked = Path.join(context.workspace, "workspace-digest-probe.txt")
    File.write!(untracked, "content\n")
    {:ok, changed_workspace_sha} = Executor.workspace_digest(context.workspace)
    refute changed_workspace_sha == initial_workspace_sha
    File.rm!(untracked)

    exclude = Path.join([context.workspace, ".git", "info", "exclude"])
    File.write!(exclude, "\n/elixir/deps/\n/elixir/_build/\n", [:append])
    generated = Path.join([context.workspace, "elixir", "_build", "generated.cache"])
    File.mkdir_p!(Path.dirname(generated))
    File.write!(generated, "ignored build output\n")
    assert Commands.git!(["check-ignore", "elixir/_build/generated.cache"], context.workspace) =~ "elixir/_build"
    {:ok, excluded_workspace_sha} = Executor.workspace_digest(context.workspace)
    assert excluded_workspace_sha == initial_workspace_sha
    File.rm_rf!(Path.join(context.workspace, "elixir"))
    resume = resume_context(context, settings, options(context, :dirty_repair) |> Keyword.put(:now_ms, fn -> expired_now end))
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    expected_digest = digest(File.read!(context.receipt))

    assert {:error, :mvp_recovery_wall_extension_invalid} =
             Executor.resume_recovery(resume, expected_digest, authorization("missing-extension", workspace_sha) |> Map.delete("wall_budget_extension_ms"))

    assert {:error, :mvp_recovery_wall_extension_invalid} =
             Executor.resume_recovery(resume, expected_digest, authorization("unbounded-extension", workspace_sha) |> Map.put("wall_budget_extension_ms", 86_400_001))

    assert {:error, :mvp_recovery_workspace_digest_mismatch} =
             Executor.resume_recovery(resume, expected_digest, authorization("wrong-digest", String.duplicate("0", 64)))

    changed_sandbox = put_in(resume, [:settings, :sandbox], %{"enabled" => true, "root" => " /bad"})

    assert {:error, :mvp_recovery_sandbox_mismatch} =
             Executor.resume_recovery(changed_sandbox, expected_digest, authorization("sandbox-mismatch", workspace_sha))

    sandbox_change = %{
      "from" => %{"enabled" => false},
      "to" => %{"enabled" => true, "root" => " /bad"}
    }

    assert {:error, :mvp_recovery_workspace_digest_mismatch} =
             Executor.resume_recovery(
               changed_sandbox,
               expected_digest,
               authorization("explicit-sandbox-change", String.duplicate("0", 64))
               |> Map.put("execution_sandbox_change", sandbox_change)
             )

    assert File.read!(context.receipt) == raw
    assert length(calls(context, :coder)) == 1
    assert calls(context, :reviewer) == []
    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
  end

  test "a valid final check failure resumes the check stage on the same candidate before review" do
    context = context!()
    check_count = Path.join(context.root, "check-count.txt")
    code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); sys.exit(10 if n==1 else 0)"
    check = ["python3", "-c", code, check_count]
    settings = settings([check])
    initial_opts = options(context, :check_resume)

    assert {:error, :mvp_recovery_resource_exhausted} = run(context, settings, initial_opts)
    before = Receipt.read(context.receipt)
    failure = before["check_failure"]
    assert failure["exit_status"] == 10
    assert calls(context, :reviewer) == []
    old_log = File.read!(failure["log_path"])

    {:ok, start, _} = DateTime.from_iso8601(before["recovery"]["started_at"])
    expired_now = DateTime.to_unix(start, :millisecond) + before["recovery"]["policy"]["max_elapsed_ms"] + 1_000
    resume = resume_context(context, settings, options(context, :check_resume) |> Keyword.put(:now_ms, fn -> expired_now end))
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)

    assert {:ok, @url} = Executor.resume_recovery(resume, digest(File.read!(context.receipt)), authorization("check-resume", workspace_sha))

    after_data = Receipt.read(context.receipt)
    [reviewer] = calls(context, :reviewer)
    assert reviewer.sha == before["candidate_sha"]
    assert length(calls(context, :coder)) == 1
    assert File.read!(failure["log_path"]) == old_log
    check_report = Path.join(operation_dir(context, "check-resume"), "check-1.json") |> File.read!() |> Jason.decode!()
    assert check_report["exit_status"] == 0
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
  end

  test "resume fails closed when recovery is disabled" do
    context = %{settings: %{max_rework: 0, recovery: %{enabled: false}}}

    assert {:error, :mvp_recovery_not_enabled} =
             Executor.resume_recovery(context, "unused", %{})
  end

  test "audited protocol resume reruns full checks and a fresh review without resetting or extending resources" do
    {context, settings, before} = protocol_blocked!()
    resume = protocol_context(context, settings)
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    auth = authorization("protocol-resume", workspace_sha) |> Map.delete("wall_budget_extension_ms")
    raw = File.read!(context.receipt)
    old_output = File.read!(Path.join(List.last(before["rounds"])["evidence"], "agent-attempt-4/output.txt"))
    assert {:ok, @url} = Executor.resume_review(resume, digest(raw), auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["recovery"]["policy"] == before["recovery"]["policy"]
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 1
    assert after_data["rework_count"] == before["rework_count"]
    assert after_data["candidate_sha"] == before["candidate_sha"]
    assert length(calls(context, :coder)) == 1
    reviewer = List.last(calls(context, :reviewer))
    assert reviewer.prompt =~ "ENTIRE"
    assert reviewer.prompt =~ "unmatched_acceptance"
    assert reviewer.prompt =~ old_output
    directory = operation_dir(context, "protocol-resume")
    audit = Path.join(directory, "authorization.json") |> File.read!() |> Jason.decode!()
    assert audit["original_recovery_policy"] == audit["effective_recovery_policy"]
    assert audit["receipt_sha256"] == digest(raw)
    assert length(audit["review_protocol_evidence"]["attempts"]) == 3
    assert length(audit["review_protocol_evidence"]["checks"]) == length(settings.checks)
    assert Enum.all?(1..length(settings.checks), &File.exists?(Path.join(directory, "check-#{&1}.json")))
    assert File.read!(Path.join(List.last(before["rounds"])["evidence"], "agent-attempt-4/output.txt")) == old_output
    assert length(calls(context, :publish)) == 1
    assert File.exists?(Path.join(directory, "completion.json"))
  end

  test "protocol resume rejects disabled recovery, changed binding, extra time and exhausted budgets" do
    disabled = %{settings: %{recovery: %{enabled: false}}}
    assert {:error, :mvp_recovery_not_enabled} = Executor.resume_review(disabled, "unused", %{})
    {context, settings, before} = protocol_blocked!()
    resume = protocol_context(context, settings)
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    auth = authorization("protocol-denied", workspace_sha) |> Map.delete("wall_budget_extension_ms")
    raw = File.read!(context.receipt)
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_review(resume, String.duplicate("0", 64), auth)
    extended = Map.put(auth, "wall_budget_extension_ms", 1)
    assert {:error, :mvp_review_protocol_budget_change} = Executor.resume_review(resume, digest(raw), extended)
    wrong_workspace = %{auth | "workspace_digest" => "wrong"}
    workspace_result = Executor.resume_review(resume, digest(raw), wrong_workspace)
    assert {:error, :mvp_recovery_workspace_digest_mismatch} = workspace_result
    changed = put_in(resume.settings.checks, [["false"]])
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_review(changed, digest(raw), auth)

    {:ok, started, _} = DateTime.from_iso8601(before["recovery"]["started_at"])
    expired = DateTime.to_unix(started, :millisecond) + settings.recovery.max_elapsed_ms
    timed_out = %{resume | opts: Keyword.put(resume.opts, :now_ms, fn -> expired end)}
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_review(timed_out, digest(raw), auth)
    exhausted = put_in(before, ["recovery", "agent_attempts"], before["recovery"]["policy"]["max_agent_attempts"])
    write_receipt!(context, exhausted)
    exhausted_raw = File.read!(context.receipt)
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_review(resume, digest(exhausted_raw), auth)
    assert File.read!(context.receipt) == exhausted_raw
    refute File.exists?(Path.join(context.receipt <> ".evidence", "operator-rechecks"))
    assert length(calls(context, :reviewer)) == 3
  end

  test "protocol evidence refuses missing, tampered and valid prior outputs instead of rewriting them" do
    {context, settings, data} = protocol_blocked!()
    resume = protocol_context(context, settings)
    assert {:ok, _} = ReviewProtocol.evidence(resume, data)
    missing_events = put_in(data, ["recovery", "events"], [])
    assert {:error, :mvp_review_protocol_evidence_mismatch} = ReviewProtocol.evidence(resume, missing_events)
    rejected = List.update_at(data["rounds"], 0, &Map.put(&1, "review", %{"approved" => false}))
    assert {:error, :mvp_review_already_rejected} = ReviewProtocol.evidence(resume, %{data | "rounds" => rejected})
    directory = List.last(data["rounds"])["evidence"]

    for {relative, replacement} <- [
          {"agent-attempt-4/output.txt", Jason.encode!(review(true))},
          {"agent-attempt-4/outcome.json", "{}"},
          {"agent-attempt-4/prompt.txt", :missing},
          {"check-1.json", "{}"},
          {"check-1.log", :missing}
        ] do
      path = Path.join(directory, relative)
      raw = File.read!(path)
      if replacement == :missing, do: File.rm!(path), else: File.write!(path, replacement)
      assert {:error, :mvp_review_protocol_evidence_mismatch} = ReviewProtocol.evidence(resume, data)
      File.write!(path, raw)
    end

    assert {:ok, _} = ReviewProtocol.evidence(resume, data)
  end

  test "a repeated protocol failure resumes from completed operator checks and retains the audit chain" do
    {context, settings, before} = protocol_blocked!()
    resume = protocol_context(context, settings)
    original = mock_agent(context, :protocol)
    invalid = Jason.encode!(%{"approved" => false, "summary" => "Still invalid", "criteria" => []})

    agent = fn workspace, prompt, issue, opts ->
      original.(workspace, prompt, issue, opts)
      {:ok, %{output_text: invalid}}
    end

    first = %{resume | opts: Keyword.put(resume.opts, :agent, agent)}
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    auth = authorization("protocol-first", workspace_sha) |> Map.delete("wall_budget_extension_ms")
    assert {:error, :mvp_invalid_review} = Executor.resume_review(first, digest(File.read!(context.receipt)), auth)
    stopped = Receipt.read(context.receipt)
    assert {:ok, evidence} = ReviewProtocol.evidence(resume, stopped)
    assert hd(evidence["checks"])["path"] == Path.join(operation_dir(context, "protocol-first"), "check-1.json")

    second_auth = %{auth | "id" => "protocol-second", "predecessor" => "protocol-first"}
    assert {:ok, @url} = Executor.resume_review(resume, digest(File.read!(context.receipt)), second_auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["recovery"]["policy"] == before["recovery"]["policy"]
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 4
    assert length(calls(context, :coder)) == 1
    head = Path.join(context.receipt <> ".evidence", "operator-rechecks/head.json") |> File.read!() |> Jason.decode!()
    assert head["id"] == "protocol-second"
    assert head["final_receipt_sha256"] == digest(File.read!(context.receipt))
  end

  test "protocol resume repairs code first then parks a genuine external condition with a concrete handoff" do
    {context, settings, before} = protocol_blocked!()
    resume = protocol_context(context, settings)
    original = mock_agent(context, :protocol)

    agent = fn workspace, prompt, issue, opts ->
      result = original.(workspace, prompt, issue, opts)

      case agent_role(opts) do
        :coder ->
          File.write!(Path.join(workspace, "candidate.txt"), "repaired assertion")
          result

        :reviewer ->
          repaired = length(calls(context, :reviewer)) > 4
          {:ok, %{output_text: Jason.encode!(mixed_protocol_review(repaired))}}
      end
    end

    resume = %{resume | opts: Keyword.put(resume.opts, :agent, agent)}
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    auth = authorization("protocol-code-first", workspace_sha) |> Map.delete("wall_budget_extension_ms")

    assert {:error, {:mvp_awaiting_external, handoff_id}} =
             Executor.resume_review(resume, digest(File.read!(context.receipt)), auth)

    after_data = Receipt.read(context.receipt)
    assert after_data["status"] == "awaiting_external"
    assert after_data["external_handoff"]["id"] == handoff_id
    assert File.exists?(after_data["external_handoff"]["record_path"])
    assert after_data["recovery"]["policy"] == before["recovery"]["policy"]
    assert after_data["rework_count"] == before["rework_count"] + 1
    refute after_data["candidate_sha"] == before["candidate_sha"]
    assert length(calls(context, :coder)) == 2
    assert length(calls(context, :reviewer)) == 5
    refute List.last(calls(context, :reviewer)).prompt =~ "Previous protocol-invalid review"
    assert calls(context, :publish) == []
    assert File.exists?(Path.join(operation_dir(context, "protocol-code-first"), "completion.json"))
  end

  defp mixed_protocol_review(repaired) do
    acceptance = hd(review(false)["criteria"])["acceptance"]
    external_acceptance = "Unattended startup with authorized credentials on the real host"
    criterion = hd(review(repaired)["criteria"])
    external_criterion = %{criterion | "acceptance" => external_acceptance, "adequate" => false}

    external = %{
      "acceptance" => external_acceptance,
      "kind" => "external_condition",
      "reason" => "The target host credential has not been provided",
      "required_evidence" => "A real unattended start log using the authorized target account",
      "handoff" => "Host operator provides credentials and records the start log"
    }

    code = %{"acceptance" => acceptance, "kind" => "code_defect", "reason" => "Repair the assertion", "required_evidence" => "", "handoff" => "coder"}
    blockers = if repaired, do: [external], else: [code, external]

    %{
      "approved" => false,
      "summary" => "Code repair precedes host evidence",
      "criteria" => [criterion, external_criterion],
      "blockers" => blockers
    }
  end

  test "a coder interrupted directly after a protocol review rejection resumes the same open round" do
    {context, settings, before} = protocol_blocked!()
    resume = protocol_context(context, settings)
    original = mock_agent(context, :dirty_repair)

    agent = fn workspace, prompt, issue, opts ->
      original.(workspace, prompt, issue, opts)

      case agent_role(opts) do
        :reviewer -> {:ok, %{output_text: Jason.encode!(review(false))}}
        :coder -> {:error, :mvp_turn_timeout}
      end
    end

    resume = %{resume | opts: Keyword.put(resume.opts, :agent, agent)}
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    auth = authorization("protocol-coder-timeout", workspace_sha) |> Map.delete("wall_budget_extension_ms")

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_review(resume, digest(File.read!(context.receipt)), auth)

    stopped = Receipt.read(context.receipt)
    assert stopped["rounds"] |> Enum.at(-2) |> get_in(["review", "approved"]) == false
    assert List.last(stopped["rounds"])["candidate_sha"] == nil
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "partial"
    next = resume_context(context, settings, options(context, :dirty_repair))
    {:ok, current_workspace} = Executor.workspace_digest(context.workspace)
    extended = authorization("protocol-coder-budget", current_workspace)
    extended = %{extended | "predecessor" => "protocol-coder-timeout"}
    assert {:ok, @url} = Executor.resume_recovery(next, digest(File.read!(context.receipt)), extended)
    after_data = Receipt.read(context.receipt)
    assert after_data["rework_count"] == stopped["rework_count"]
    assert length(after_data["rounds"]) == length(stopped["rounds"])
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "completed from partial"
    assert length(calls(context, :coder)) == 3
    assert length(calls(context, :publish)) == 1
  end

  test "another interrupted coder preserves a review from an audited ancestor operation" do
    for corrupt <- [false, true] do
      {context, settings, _before} = protocol_blocked!()
      resume = protocol_context(context, settings)
      original = mock_agent(context, :dirty_repair)

      timeout_agent = fn workspace, prompt, issue, opts ->
        original.(workspace, prompt, issue, opts)

        if agent_role(opts) == :reviewer,
          do: {:ok, %{output_text: Jason.encode!(review(false))}},
          else: {:error, :mvp_turn_timeout}
      end

      resume = %{resume | opts: Keyword.put(resume.opts, :agent, timeout_agent)}
      {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
      auth = authorization("ancestor-review", workspace_sha) |> Map.delete("wall_budget_extension_ms")
      assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_review(resume, digest(File.read!(context.receipt)), auth)

      base_now = System.system_time(:millisecond)
      Process.put({context.key, :resume_now}, base_now + 7_500_000)

      interrupted = fn workspace, prompt, issue, opts ->
        original.(workspace, prompt, issue, opts)
        File.write!(Path.join(workspace, "candidate.txt"), "partial again")
        Process.put({context.key, :resume_now}, base_now + 9_000_000)
        {:error, :mvp_turn_timeout}
      end

      opts = options(context, :dirty_repair) |> Keyword.put(:now_ms, fn -> Process.get({context.key, :resume_now}) end) |> Keyword.put(:agent, interrupted)
      next = resume_context(context, settings, opts)
      {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
      auth = authorization("ancestor-coder-timeout", workspace_sha) |> Map.put("predecessor", "ancestor-review")
      assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_recovery(next, digest(File.read!(context.receipt)), auth)
      stopped = Receipt.read(context.receipt)
      effective = %{settings | recovery: %{settings.recovery | max_elapsed_ms: stopped["recovery"]["policy"]["max_elapsed_ms"]}}
      opts = options(context, :dirty_repair) |> Keyword.put(:now_ms, fn -> base_now + 9_000_000 end)
      final = resume_context(context, effective, opts)
      {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
      auth = authorization("ancestor-final", workspace_sha) |> Map.put("predecessor", "ancestor-coder-timeout")

      if corrupt do
        path = Path.join([context.receipt <> ".evidence", "operator-rechecks", "ancestor-coder-timeout", "receipt-before.json"])
        File.write!(path, "{}")
        assert {:error, :mvp_recovery_resume_stage_unsupported} = Executor.resume_recovery(final, digest(File.read!(context.receipt)), auth)
        assert File.read!(Path.join(context.workspace, "candidate.txt")) == "partial again"
      else
        assert {:ok, @url} = Executor.resume_recovery(final, digest(File.read!(context.receipt)), auth)
        assert Receipt.read(context.receipt)["rework_count"] == stopped["rework_count"]
        assert length(calls(context, :publish)) == 1
      end
    end
  end

  defp protocol_blocked! do
    context = context!()
    settings = settings([["true"], ["true"]])
    original = mock_agent(context, :protocol)

    invalid =
      review(false)
      |> Map.put("blockers", [%{"acceptance" => "combined title", "kind" => "code_defect", "reason" => "Repair an assertion", "required_evidence" => "", "handoff" => "coder"}])
      |> Jason.encode!()

    agent = fn workspace, prompt, issue, opts ->
      result = original.(workspace, prompt, issue, opts)
      if agent_role(opts) == :reviewer, do: {:ok, %{output_text: invalid}}, else: result
    end

    opts = options(context, :protocol) |> Keyword.put(:agent, agent) |> Keyword.put(:on_message, fn _ -> :ok end)
    assert {:error, :mvp_invalid_review} = run(context, settings, opts)
    {context, settings, Receipt.read(context.receipt)}
  end

  defp protocol_context(context, settings),
    do: resume_context(context, settings, options(context, :protocol) |> Keyword.put(:on_message, fn _ -> :ok end))

  test "resume rejects an open coder round when no persisted rejected review remains" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    rounds = clear_review(data["rounds"], 9)
    data = data |> Map.drop(["review", "comment", "execution_sandbox"]) |> Map.put("rounds", rounds)
    write_receipt!(context, data)

    {resume, auth} = resume_inputs!(context, settings, "missing-review")

    assert {:error, :mvp_recovery_resume_stage_unsupported} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    data = Receipt.read(context.receipt)
    head = Commands.git!(["rev-parse", "HEAD"], context.workspace)
    rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "candidate_sha", head))
    write_receipt!(context, Map.merge(data, %{"rounds" => rounds, "candidate_sha" => head}))
    {resume, auth} = resume_inputs!(context, settings, "unsupported-stage")

    assert {:error, :mvp_recovery_resume_stage_unsupported} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    refute File.exists?(Path.join([context.receipt <> ".evidence", "operator-rechecks"]))
  end

  test "resume rejects tampered persisted review evidence before creating an audit" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    review_path = Enum.at(data["rounds"], 8)["review_path"]
    File.write!(review_path, "not review JSON")
    {resume, auth} = resume_inputs!(context, settings, "tampered-review")

    assert {:error, :mvp_recovery_resume_stage_unsupported} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    refute File.exists?(operation_dir(context, "tampered-review"))
  end

  test "an interrupted first coder round cannot resume without a preceding completed candidate" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    first = Map.merge(hd(data["rounds"]), %{"candidate_sha" => nil, "review" => nil, "comment" => nil})
    Receipt.update(context.receipt, "blocked", %{"rounds" => [first], "candidate_sha" => nil, "rework_count" => 0, "review" => nil, "comment" => nil})
    {resume, auth} = resume_inputs!(context, settings, "missing-preceding-candidate")

    assert {:error, :mvp_resume_binding_mismatch} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    refute File.exists?(operation_dir(context, "missing-preceding-candidate"))
  end

  test "open coder resume rejects a candidate from a history unrelated to the rejected revision" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    Commands.git!(["reset", "--hard", data["base_sha"]], context.workspace)
    unrelated = commit_fixture_file(context, "other.txt", "different history", "unrelated candidate")
    rounds = List.update_at(data["rounds"], 10, &Map.put(&1, "candidate_sha", unrelated))
    Receipt.update(context.receipt, "blocked", %{"rounds" => rounds, "candidate_sha" => unrelated})
    {resume, auth} = resume_inputs!(context, settings, "unrelated-candidate")

    assert {:error, :mvp_recovery_resume_stage_unsupported} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    refute File.exists?(operation_dir(context, "unrelated-candidate"))
  end

  test "check failure after an older rejection rechecks the newer candidate" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    head = Commands.git!(["rev-parse", "HEAD"], context.workspace)
    Commands.git!(["reset", "--hard", head], context.workspace)
    rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "candidate_sha", head))
    rounds = put_round_check_failure(rounds, 12, 10, settings.checks)
    failure = List.last(rounds)["check_failure"]
    Receipt.update(context.receipt, "blocked", %{"rounds" => rounds, "candidate_sha" => head, "check_failure" => failure})
    {resume, auth} = resume_inputs!(context, settings, "newer-check-failure")

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    [reviewer] = calls(context, :reviewer)
    assert reviewer.sha == head
    assert length(calls(context, :coder)) == 1
  end

  test "check failure on the rejected head repairs it without rechecking the rejected candidate" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    rejected_sha = Enum.at(data["rounds"], 8)["candidate_sha"]
    Commands.git!(["reset", "--hard", rejected_sha], context.workspace)
    rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "candidate_sha", rejected_sha))
    rounds = put_round_check_failure(rounds, 12, 10, settings.checks)
    failure = List.last(rounds)["check_failure"]

    Receipt.update(context.receipt, "blocked", %{
      "rounds" => rounds,
      "candidate_sha" => rejected_sha,
      "check_failure" => failure
    })

    {resume, auth} = resume_inputs!(context, settings, "repair-rejected-head")

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    [reviewer] = calls(context, :reviewer)
    refute reviewer.sha == rejected_sha
    assert length(calls(context, :coder)) == 2
    assert Enum.at(calls(context, :coder), 1).existing == "initial"
  end

  test "open coder resume without a recent check failure passes only the rejection diagnostic" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    rounds = Enum.map(data["rounds"], &Map.put(&1, "check_failure", nil))
    Receipt.update(context.receipt, "blocked", %{"rounds" => rounds, "check_failure" => nil})
    {resume, auth} = resume_inputs!(context, settings, "rejection-without-check-failure")

    assert {:ok, @url} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    resumed_coder = Enum.at(calls(context, :coder), 1)
    assert resumed_coder.prompt =~ "The candidate needs a focused correction"
    assert resumed_coder.prompt =~ "operator_diagnostic"
    refute resumed_coder.prompt =~ "Most recent check failure"
  end

  test "open coder resume preserves a failed View preflight without a child exit code and reruns every check" do
    context = context!()
    {settings, before} = view_preflight_history!(context)
    failure = put_view_preflight_failure!(context, before, :valid)
    {resume, auth} = resume_inputs!(context, settings, "view-preflight-resume")
    resume = Map.update!(resume, :opts, &sandbox_callbacks(&1, context))

    assert {:ok, @url} = Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)
    after_data = Receipt.read(context.receipt)
    assert Enum.at(after_data["rounds"], 10)["check_failure"] == failure
    assert is_nil(failure["exit_status"])
    assert Enum.at(calls(context, :coder), 1).prompt =~ "sandbox_check_evidence_missing"
    assert length(calls(context, :reviewer)) == 1
    assert length(calls(context, :sandbox_check)) == 10
    assert after_data["rework_count"] == before["rework_count"]
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
  end

  test "open coder resume rejects unsupported or tampered no-exit-code View evidence without changing state" do
    corruptions =
      [:malformed, :passed, :unknown_error, :wrong_command] ++
        [:wrong_failure, :zero_exit, :unknown_transport, :missing_log, :non_view, :non_isolated]

    for corruption <- corruptions do
      context = context!()
      {settings, before} = view_preflight_history!(context, corruption)
      put_view_preflight_failure!(context, before, corruption)
      {resume, auth} = resume_inputs!(context, settings, "invalid-view-preflight")
      raw = File.read!(context.receipt)

      assert {:error, :mvp_recovery_resume_stage_unsupported} = Executor.resume_recovery(resume, digest(raw), auth)
      assert File.read!(context.receipt) == raw
      assert length(calls(context, :coder)) == 1
      assert calls(context, :reviewer) == []
      refute File.exists?(operation_dir(context, "invalid-view-preflight"))
    end
  end

  defp view_preflight_history!(context, corruption \\ :valid) do
    before = blocked_gh5!(context, settings())
    sandbox = sandbox_profile!(context).settings
    sandbox = if corruption == :non_isolated, do: %{enabled: false}, else: sandbox
    script = if corruption == :non_view, do: "check_candidate.py", else: "check_view.py"
    checks = List.duplicate(["python3", "{baseline}/scripts/" <> script], 10)
    updated = before |> Map.put("execution_sandbox", json_map(sandbox)) |> Map.update!("rounds", &Enum.map(&1, fn round -> Map.put(round, "checks", checks) end))
    write_receipt!(context, updated)
    {%{settings() | checks: checks, sandbox: sandbox}, updated}
  end

  defp put_view_preflight_failure!(context, before, corruption) do
    round = Enum.at(before["rounds"], 10)
    log = Path.join(round["evidence"], "check-10.log")

    report = %{
      "schema_version" => 1,
      "kind" => "controller_view_check",
      "controller_view_check" => true,
      "passed" => false,
      "formal_code_checks" => false,
      "formal_acceptance" => false,
      "real_windows_wsl_acceptance" => false,
      "candidate_sha" => nil,
      "error" => "ValueError: candidate worktree is dirty; disk file list differs from HEAD, including ignored files"
    }

    report = corrupt_view_report(report, corruption)

    command = Enum.map(Enum.at(round["checks"], 9), &String.replace(&1, "{baseline}", Path.join(context.receipt <> ".evidence", "baseline")))
    failure = %{"index" => 10, "argv" => command, "log_path" => log, "exit_status" => nil, "error" => "{:error, :sandbox_check_evidence_missing}", "repairable" => false}

    failure = corrupt_view_failure(failure, corruption)

    File.write!(log, if(corruption == :malformed, do: "invalid JSON", else: Jason.encode!(report)))
    File.write!(Path.rootname(log) <> ".json", Jason.encode!(if(corruption == :wrong_failure, do: Map.put(failure, "repairable", true), else: failure)))
    if corruption == :missing_log, do: File.rm!(log)
    rounds = List.update_at(before["rounds"], 10, &Map.put(&1, "check_failure", failure))
    Receipt.update(context.receipt, "blocked", %{"rounds" => rounds})
    failure
  end

  defp corrupt_view_report(report, :passed), do: Map.put(report, "passed", true)
  defp corrupt_view_report(report, :unknown_error), do: Map.put(report, "error", "unverified transport failure")
  defp corrupt_view_report(report, _), do: report

  defp corrupt_view_failure(failure, :wrong_command), do: Map.put(failure, "argv", ["untrusted"])
  defp corrupt_view_failure(failure, :zero_exit), do: Map.put(failure, "exit_status", 0)
  defp corrupt_view_failure(failure, :unknown_transport), do: Map.put(failure, "error", "{:error, :unknown}")
  defp corrupt_view_failure(failure, _), do: failure

  test "resume refuses rejected repair when no additional round remains" do
    context = context!()
    settings = settings()
    data = blocked_gh5!(context, settings)
    rounds = final_rejected_rounds!(context, data)
    final_review = List.last(rounds)["review"]
    final_comment = List.last(rounds)["comment"]

    Receipt.update(context.receipt, "blocked", %{
      "rounds" => rounds,
      "rework_count" => 20,
      "candidate_sha" => data["candidate_sha"],
      "review" => final_review,
      "comment" => final_comment
    })

    {resume, auth} = resume_inputs!(context, settings, "no-round-budget")

    assert {:error, :mvp_recovery_resource_exhausted} =
             Executor.resume_recovery(resume, digest(File.read!(context.receipt)), auth)

    refute File.exists?(operation_dir(context, "no-round-budget"))
  end

  defp blocked_gh5!(context, settings) do
    assert {:error, :mvp_recovery_resource_exhausted} = run(context, settings, options(context, :dirty_repair))
    prepare_gh5_history!(context, settings)
    Receipt.read(context.receipt)
  end

  defp clear_review(rounds, number) do
    List.update_at(rounds, number - 1, &Map.merge(&1, %{"review" => nil, "comment" => nil, "review_path" => nil}))
  end

  defp write_receipt!(context, data), do: File.write!(context.receipt, Jason.encode!(data))

  defp resume_inputs!(context, settings, id) do
    data = Receipt.read(context.receipt)
    {:ok, start, _} = DateTime.from_iso8601(data["recovery"]["started_at"])
    now = DateTime.to_unix(start, :millisecond) + data["recovery"]["policy"]["max_elapsed_ms"] + 1_000
    opts = options(context, :dirty_repair) |> Keyword.put(:now_ms, fn -> now end)
    {:ok, workspace_sha} = Executor.workspace_digest(context.workspace)
    {resume_context(context, settings, opts), authorization(id, workspace_sha)}
  end

  defp final_rejected_rounds!(context, data) do
    rounds =
      Enum.map(1..21, fn number ->
        evidence = Path.join(context.receipt <> ".evidence", "round-#{number}")
        File.mkdir_p!(evidence)

        Map.merge(hd(data["rounds"]), %{
          "round" => number,
          "evidence" => evidence,
          "candidate_sha" => data["candidate_sha"],
          "review" => nil,
          "comment" => nil,
          "review_path" => nil,
          "check_failure" => nil
        })
      end)

    review = review(false)
    path = Path.join(List.last(rounds)["evidence"], "review.json")
    File.write!(path, Jason.encode!(review))
    comment = %{"id" => 21, "candidate_sha" => data["candidate_sha"], "round" => 21}
    List.update_at(rounds, -1, &Map.merge(&1, %{"review" => review, "comment" => comment, "review_path" => path}))
  end

  defp context! do
    root = Path.join(System.tmp_dir!(), "mvp-recovery-resume-#{System.unique_integer([:positive])}")
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
      title: "Resume a bounded task",
      description: "Preserve an incomplete repair and finish the checked behavior.",
      native_ref: %{"repo" => "owner/repo", "number" => 42},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)
    repository = %{repo: "owner/repo", base: "main", url: remote}

    %{
      root: root,
      workspace: workspace,
      repository: repository,
      issue: issue,
      receipt: receipt,
      key: make_ref()
    }
  end

  defp settings(checks \\ List.duplicate(["true"], 10)) do
    {:ok, policy} = Recovery.settings(%{"enabled" => true, "max_rework" => 20})
    %{checks: checks, check_timeout_ms: 10_000, max_rework: 5, recovery: policy, sandbox: %{enabled: false}}
  end

  defp run(context, settings, opts) do
    Executor.run(context.workspace, context.issue, settings, models(), context.receipt, opts)
  end

  defp models, do: %{coder: "coder-model", reviewer: "reviewer-model"}

  defp options(context, behavior) do
    [
      repository: repository_callback(context),
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}},
      now_ms: now_callback(context),
      on_message: &handle_message(context, &1),
      agent: mock_agent(context, behavior),
      publish: publish_callback(context),
      request_fun: comment_callback(context)
    ]
  end

  defp repository_callback(context), do: fn _, _ -> {:ok, context.repository} end

  defp now_callback(context) do
    fn ->
      if Process.get({context.key, :elapsed}, false),
        do: System.system_time(:millisecond) + 7_500_000,
        else: System.system_time(:millisecond)
    end
  end

  defp handle_message(context, %{event: :mvp_check_started}), do: Process.put({context.key, :elapsed}, true)
  defp handle_message(_context, _message), do: :ok

  defp mock_agent(context, behavior) do
    fn workspace, prompt, _issue, opts ->
      role = agent_role(opts)
      existing = File.read(Path.join(workspace, "candidate.txt")) |> elem_or_nil()
      sha = Commands.git!(["rev-parse", "HEAD"], workspace)
      record(context, role, %{sha: sha, prompt: prompt, existing: existing, model: opts[:model]})
      opts[:on_message].(%{usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}})
      mock_agent_result(context, behavior, workspace, role, opts)
    end
  end

  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(_), do: nil

  defp mock_agent_result(context, behavior, workspace, :coder, _opts) do
    update_mock_candidate(context, behavior, workspace, length(calls(context, :coder)))
    {:ok, %{output_text: "Implemented the checked behavior"}}
  end

  defp mock_agent_result(context, behavior, _workspace, :reviewer, _opts) do
    approved = reviewer_approval(context, behavior)
    {:ok, %{output_text: Jason.encode!(review(approved))}}
  end

  defp mock_agent_result(_context, _behavior, _workspace, :diagnosis, _opts) do
    diagnosis = %{
      "action" => "repair_code",
      "summary" => "Continue the repair",
      "steps" => ["preserve the current workspace and finish the fix"]
    }

    {:ok, %{output_text: Jason.encode!(diagnosis)}}
  end

  defp update_mock_candidate(context, :dirty_repair, workspace, call) do
    if Process.get({context.key, :synthetic_history}, false) do
      File.write!(Path.join(workspace, "candidate.txt"), "completed from partial")
    else
      update_dirty_candidate(workspace, call, context)
    end
  end

  defp update_mock_candidate(_context, _behavior, workspace, _call),
    do: File.write!(Path.join(workspace, "candidate.txt"), "initial")

  defp update_dirty_candidate(workspace, 1, _context),
    do: File.write!(Path.join(workspace, "candidate.txt"), "initial")

  defp update_dirty_candidate(workspace, 2, context) do
    File.write!(Path.join(workspace, "candidate.txt"), "partial")
    Process.put({context.key, :elapsed}, true)
  end

  defp update_dirty_candidate(workspace, _call, _context),
    do: File.write!(Path.join(workspace, "candidate.txt"), "completed from partial")

  defp reviewer_approval(context, :dirty_repair) do
    Process.get({context.key, :synthetic_history}, false) or length(calls(context, :reviewer)) > 1
  end

  defp reviewer_approval(_context, _behavior), do: true

  defp publish_callback(context) do
    fn _, _, _, _, sha, _, _ ->
      record(context, :publish, %{sha: sha})
      {:ok, @url}
    end
  end

  defp comment_callback(context) do
    fn "POST", "/repos/owner/repo/issues/42/comments", %{}, body, _ ->
      record(context, :comment, body)
      {:ok, %{status: 201, body: %{"id" => length(calls(context, :comment)), "body" => body["body"]}}}
    end
  end

  defp sandbox_profile!(context) do
    paths = %{
      "root" => Path.join(context.root, "sandbox-runs"),
      "toolchain" => Path.join(context.root, "toolchain"),
      "codex" => Path.join(context.root, "codex"),
      "dependencies" => Path.join(context.root, "dependencies"),
      "trusted_root" => Path.join(context.root, "trusted"),
      "auth_home" => Path.join(context.root, "auth")
    }

    Enum.each(Map.values(paths), &File.mkdir_p!/1)
    File.write!(Path.join(paths["auth_home"], "auth.json"), "fake sandbox model auth")
    script = Path.join(context.root, "check_candidate.py")
    File.write!(script, "import sys\nsys.exit(0)\n")
    config = Map.put(paths, "enabled", true)
    {:ok, settings} = ExecutionSandbox.settings(config)
    %{settings: settings, script: script}
  end

  defp sandbox_callbacks(opts, context) do
    opts
    |> Keyword.put(:sandbox_agent_run, sandbox_agent_callback(context))
    |> Keyword.put(:sandbox_command_run, sandbox_command_callback(context))
    |> Keyword.put(:sandbox_cleanup_timeout_ms, 1_000)
  end

  defp sandbox_agent_callback(context) do
    fn workspace, prompt, _issue, options ->
      role = agent_role(options)
      scratch = sandbox_scratch(options)
      record(context, :sandbox_agent, %{role: role})
      record_sandbox_agent_call(context, role, workspace, prompt, options)
      sandbox_agent_export(role, scratch)
      sandbox_result!(scratch, 0)
      {:ok, %{output_text: sandbox_agent_output(role)}}
    end
  end

  defp record_sandbox_agent_call(context, role, workspace, prompt, options) do
    existing = File.read(Path.join(workspace, "candidate.txt")) |> elem_or_nil()
    sha = Commands.git!(["rev-parse", "HEAD"], workspace)
    record(context, role, %{sha: sha, prompt: prompt, existing: existing, model: options[:model]})
  end

  defp sandbox_agent_export(:coder, scratch) do
    export = Path.join([scratch, "export", "candidate.txt"])
    File.mkdir_p!(Path.dirname(export))
    File.write!(export, "completed from partial")
  end

  defp sandbox_agent_export(_role, _scratch), do: :ok

  defp sandbox_agent_output(:reviewer), do: Jason.encode!(review(true))
  defp sandbox_agent_output(_role), do: "Finished the resumed implementation"

  defp sandbox_command_callback(context) do
    fn argv, workspace, _timeout, output ->
      scratch = sandbox_argv_value(argv, "--scratch-root")
      report = Path.join([scratch, "export", ".check-evidence", "report.json"])
      File.mkdir_p!(Path.dirname(report))
      File.write!(report, "complete check report")
      sandbox_result!(scratch, 0)
      File.write!(output, "sandbox check passed")
      record(context, :sandbox_check, %{workspace: workspace, argv: argv})
      {:ok, 0}
    end
  end

  defp sandbox_result!(scratch, status) do
    File.mkdir_p!(scratch)

    result = %{
      "cleanup_complete" => true,
      "export_complete" => true,
      "scratch_root" => scratch,
      "exit_status" => status
    }

    File.write!(Path.join(scratch, "result.json"), Jason.encode!(result))
  end

  defp sandbox_scratch(options),
    do: options[:execution_environment].codex_home |> Path.dirname() |> Path.join("sandbox")

  defp sandbox_argv_value(argv, flag), do: argv |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp json_map(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp prepare_gh5_history!(context, settings) do
    # This test constructs persisted GH5-shaped evidence; only the post-resume mock calls are real invocations.
    data = Receipt.read(context.receipt)
    initial = hd(data["rounds"])
    rejected_sha = initial["candidate_sha"]
    review = review(false)
    comment = %{"id" => 1, "candidate_sha" => rejected_sha, "round" => 9, "body" => "fixture rejection"}
    {round10_sha, round11_sha} = append_gh5_candidates(context)
    rounds = build_gh5_rounds(context, initial, review, comment, settings.checks, rejected_sha, round10_sha, round11_sha)
    rounds = persist_gh5_evidence(rounds, settings.checks, review)
    mark_dirty_coder_workspace(context)
    persist_gh5_receipt(context, data, rounds, review, comment, round11_sha)
  end

  defp append_gh5_candidates(context) do
    round10 = commit_fixture_file(context, "round-10.txt", "check failure 1\n", "round 10 candidate")
    round11 = commit_fixture_file(context, "round-11.txt", "check failure 10\n", "round 11 candidate")
    {round10, round11}
  end

  defp commit_fixture_file(context, path, contents, message) do
    File.write!(Path.join(context.workspace, path), contents)
    Commands.git!(["add", path], context.workspace)
    Commands.git!(["commit", "-m", message], context.workspace)
    Commands.git!(["rev-parse", "HEAD"], context.workspace)
  end

  defp build_gh5_rounds(context, initial, review, comment, checks, rejected_sha, round10_sha, round11_sha) do
    Enum.map(1..12, fn number ->
      gh5_round(context, initial, number, checks, {rejected_sha, round10_sha, round11_sha}, review, comment)
    end)
  end

  defp gh5_round(context, initial, number, checks, candidate_shas, review, comment) do
    evidence = Path.join(context.receipt <> ".evidence", "round-#{number}")
    File.mkdir_p!(evidence)
    {round_review, round_comment, review_path} = review_evidence(number, evidence, review, comment)

    Map.merge(initial, %{
      "round" => number,
      "candidate_sha" => gh5_candidate_sha(number, candidate_shas),
      "evidence" => evidence,
      "checks" => checks,
      "review" => round_review,
      "comment" => round_comment,
      "review_path" => review_path,
      "check_failure" => nil
    })
  end

  defp gh5_candidate_sha(12, _shas), do: nil
  defp gh5_candidate_sha(number, {rejected, _round10, _round11}) when number < 10, do: rejected
  defp gh5_candidate_sha(10, {_rejected, round10, _round11}), do: round10
  defp gh5_candidate_sha(_number, {_rejected, _round10, round11}), do: round11

  defp review_evidence(9, evidence, review, comment),
    do: {review, comment, Path.join(evidence, "review.json")}

  defp review_evidence(_number, _evidence, _review, _comment), do: {nil, nil, nil}

  defp persist_gh5_evidence(rounds, checks, review) do
    review_path = Enum.at(rounds, 8)["review_path"]
    File.write!(review_path, Jason.encode!(review))
    rounds |> put_round_check_failure(10, 1, checks) |> put_round_check_failure(11, 10, checks)
  end

  defp mark_dirty_coder_workspace(context) do
    File.write!(Path.join(context.workspace, "candidate.txt"), "partial")
    Process.put({context.key, :synthetic_history}, true)
  end

  defp persist_gh5_receipt(context, data, rounds, review, comment, current_sha) do
    recovery = synthetic_recovery(data["recovery"])

    Receipt.update(context.receipt, "blocked", %{
      "rounds" => rounds,
      "candidate_sha" => current_sha,
      "rework_count" => 11,
      "max_rework" => 20,
      "review" => review,
      "comment" => comment,
      "recovery" => recovery,
      "check_failure" => nil
    })
  end

  defp synthetic_recovery(recovery) do
    recovery
    |> Map.put("agent_attempts", 21)
    |> Map.put("adopted_agent_attempts", 21)
    |> Map.put("adopted_rework_count", 11)
    |> Map.put("events", Enum.map(1..11, &%{"round" => &1, "kind" => "synthetic_prior_round"}))
  end

  defp put_round_check_failure(rounds, round_number, index, checks) do
    evidence = Path.join(Path.dirname(hd(rounds)["evidence"]), "round-#{round_number}")
    log_path = Path.join(evidence, "check-#{index}.log")

    failure = %{
      "index" => index,
      "argv" => Enum.at(checks, index - 1),
      "log_path" => log_path,
      "exit_status" => 10,
      "repairable" => true,
      "diagnostic" => check_diagnostic(index)
    }

    File.write!(log_path, failure["diagnostic"] <> "\n")
    File.write!(Path.rootname(log_path) <> ".json", Jason.encode!(failure, pretty: true))
    List.update_at(rounds, round_number - 1, &Map.put(&1, "check_failure", failure))
  end

  defp check_diagnostic(10), do: "Most recent check failure"
  defp check_diagnostic(_index), do: "Earlier check failure"

  defp resume_context(context, settings, opts) do
    data = Receipt.read(context.receipt)
    evidence = context.receipt <> ".evidence"
    baseline = Path.join(evidence, "baseline")

    baseline_digest =
      Path.wildcard(Path.join(baseline, "**/*"), match_dot: true)
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, baseline)

        case File.lstat!(path) do
          %{type: :regular} -> {relative, :crypto.hash(:sha256, File.read!(path))}
          %{type: :symlink} -> {relative, File.read_link!(path)}
          %{type: type} -> {relative, type}
        end
      end)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Map.merge(context, %{
      settings: settings,
      models: models(),
      services: data["services"],
      opts: opts,
      branch: data["branch"],
      evidence: evidence,
      base: data["base_sha"],
      baseline_digest: baseline_digest,
      limit: 5,
      metadata: Map.new([".git/config", ".git/info/attributes", ".git/info/exclude"], &{&1, File.read(Path.join(context.workspace, &1))})
    })
  end

  defp authorization(id, workspace_sha) do
    %{
      "id" => id,
      "authorization" => "Explicit test authorization for this one blocked task",
      "runtime_version" => String.duplicate("a", 40),
      "command" => ["operator", "resume", id],
      "diagnostic" => "Continue the authorized task from its saved evidence",
      "legacy_closures" => [],
      "predecessor" => nil,
      "workspace_digest" => workspace_sha,
      "wall_budget_extension_ms" => 1_000_000
    }
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
      "summary" => if(approved, do: "The implementation meets the checked behavior", else: "The candidate needs a focused correction"),
      "criteria" => [
        %{
          "acceptance" => "Preserve an incomplete repair and finish the checked behavior",
          "tests" => ["controller resume test"],
          "assertion_strength" => "Checks the resulting workspace value",
          "failure_sensitivity" => "An incomplete value fails the assertion",
          "adequate" => approved
        }
      ]
    }
  end

  defp operation_dir(context, id), do: Path.join([context.receipt <> ".evidence", "operator-rechecks", id])
  defp record(context, role, value), do: Process.put({context.key, role}, calls(context, role) ++ [value])
  defp calls(context, role), do: Process.get({context.key, role}, [])
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
