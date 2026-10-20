defmodule SymphonyElixir.Mvp.RestartRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Commands, Executor, ExternalHandoff, Receipt, Recovery, RestartRecovery}

  test "only explicitly opted-in new VM receipts qualify; live and unknown controllers are excluded" do
    c = context!()
    refute RestartRecovery.enabled?(%{})
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    assert RestartRecovery.pending?(c.receipt, c.settings)
    assert {:error, :mvp_restart_freeze_invalid} = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    assert {:ok, owner} = RestartRecovery.owner()
    assert {:error, :mvp_restart_active} = RestartRecovery.owner_dead(owner)
    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner_dead(nil)
    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner_dead(Map.put(owner, "machine_sha256", "other"))
    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner_dead(Map.put(owner, "pid_namespace", "other"))
    assert :ok = RestartRecovery.owner_dead(Map.put(owner, "starttime", "0"))
    assert :ok = RestartRecovery.owner_dead(Map.put(owner, "boot_id", "previous-boot"))
    dead!(c)
    assert RestartRecovery.eligible?(c.receipt, c.settings)

    disabled_settings = [
      put_in(c.settings.recovery.resume_on_restart, false),
      put_in(c.settings.sandbox.enabled, true),
      put_in(c.settings.execution_readiness.required_backend, "rootless")
    ]

    for settings <- disabled_settings do
      refute RestartRecovery.enabled?(settings)
      refute RestartRecovery.eligible?(c.receipt, settings)
    end

    Receipt.update(c.receipt, "blocked")
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    Receipt.update(c.receipt, "blocked", %{"rounds" => [%{}], "reason" => nil})
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    File.write!(c.receipt, "broken")
    refute RestartRecovery.eligible?(c.receipt, c.settings)
  end

  test "claimed receipt resumes from the same base without resetting the initial time anchor" do
    c = context!()
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    anchor = Receipt.read(c.receipt)["restart_recovery"]["started_at"]
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    data = Receipt.read(c.receipt)
    assert data["recovery"]["started_at"] == anchor
    assert data["recovery"]["agent_attempts"] == 2
    assert data["restart_recovery"]["generation"] == 1
    assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    assert Enum.all?(Enum.filter(data["recovery"]["events"], &(&1["status"] == "finished")), &is_binary(&1["source_after_model"]))
    refute RestartRecovery.eligible?(c.receipt, c.settings)
  end

  test "pending contracts retain live and unknown owners, while old and stopped tasks are excluded" do
    c = context!()
    refute RestartRecovery.pending?(c.receipt, c.settings)
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    assert RestartRecovery.pending?(c.receipt, c.settings)
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    update_restart(c, &put_in(&1, ["owner", "machine_sha256"], "unknown-machine"))
    assert RestartRecovery.pending?(c.receipt, c.settings)
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    dead!(c)
    assert RestartRecovery.eligible?(c.receipt, c.settings)
    assert {:error, :revoked} = RestartRecovery.stop(c.receipt, c.issue, c.settings, {:error, :revoked})
    refute RestartRecovery.pending?(c.receipt, c.settings)
    refute RestartRecovery.eligible?(c.receipt, c.settings)
  end

  test "withdrawn ready or a terminal issue blocks restart before any fresh model call and leaves a stop journal" do
    for mutation <- [:ready_removed, :closed] do
      c = interrupted_check!()
      before = File.read!(c.receipt)
      issue = if mutation == :ready_removed, do: %{c.issue | labels: []}, else: %{c.issue | state: "closed"}
      dead!(c)
      raw = File.read!(c.receipt)

      assert {:error, :mvp_restart_issue_not_ready} =
               Executor.resume_restart(c.workspace, issue, c.settings, models(), c.receipt, options(c))

      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 0 and calls(c, :publish) == 0
      assert File.read!(c.receipt) == raw
      assert Jason.decode!(raw)["recovery"] == Jason.decode!(before)["recovery"]
      journal = File.read!(c.receipt <> ".restart-blocked.json") |> Jason.decode!()
      assert journal["reason"] == ":mvp_restart_issue_not_ready"
      refute RestartRecovery.pending?(c.receipt, c.settings)
    end
  end

  test "claim interrupted before workspace creation initializes only its frozen new-task path" do
    c = context!()
    File.rename!(c.workspace, c.workspace <> "-retained")
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    assert File.read!(Path.join(c.workspace, "candidate.txt")) == "candidate 1"
    assert File.read!(Path.join(c.workspace <> "-retained", "source.txt")) == "base"
    assert Receipt.read(c.receipt)["workspace"] == c.workspace
  end

  test "restart freezes ready authorization policy without resolving new models" do
    for {key, value} <- [ready_label: "other", allowed_actors: ["other"], allowed_models: ["other"]] do
      c = interrupted_check!()
      frozen = Receipt.read(c.receipt)["restart_recovery"]["settings"]
      assert frozen[Atom.to_string(key)] == c.settings[key]
      dead!(c)
      settings = Map.put(c.settings, key, value)
      assert {:error, _} = RestartRecovery.resume(c.workspace, c.issue, settings, models(), c.receipt, options(c))
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 0 and calls(c, :publish) == 0
    end
  end

  test "checkpoints before the first round or its first reservation resume their unspent model call" do
    for stage <- [:before_round, :before_reservation] do
      c = context!()

      clock = fn ->
        data = Receipt.read(c.receipt)
        checkpoint = get_in(data, ["restart_recovery", "checkpoint"])
        round_started = (data["rounds"] || []) != []
        expected = stage == :before_reservation
        if checkpoint && round_started == expected, do: throw(:before_model_reservation)
        System.system_time(:millisecond)
      end

      opts = Keyword.put(options(c), :now_ms, clock)
      assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :before_model_reservation
      before = Receipt.read(c.receipt)
      assert before["recovery"]["agent_attempts"] == 0
      assert before["recovery"]["events"] == []
      assert calls(c, :coder) == 0
      dead!(c)
      assert {:ok, "local-draft"} = resume(c)
      assert Receipt.read(c.receipt)["recovery"]["started_at"] == before["recovery"]["started_at"]
      assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == 2
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    end
  end

  test "inconsistent hydrated metadata or unknown execution stage stops without another call" do
    for mutation <- [:receipt_models, :stage, :missing_feedback, :diagnosis_candidate] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)

      case mutation do
        :receipt_models ->
          Receipt.update(c.receipt, "checking", %{"models" => %{"coder" => "different", "reviewer" => "reviewer"}})

        :stage ->
          Receipt.update(c.receipt, "preparing")

        :missing_feedback ->
          Receipt.update(c.receipt, "recovering")

        :diagnosis_candidate ->
          rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "candidate_sha", data["base_sha"]))
          recovery = Map.update!(data["recovery"], "events", &(&1 ++ [%{"feedback" => review(false)}]))
          Receipt.update(c.receipt, "recovering", %{"rounds" => rounds, "recovery" => recovery})
      end

      dead!(c)
      assert {:error, _} = resume(c)
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 0 and calls(c, :publish) == 0
      assert File.exists?(c.receipt <> ".restart-blocked.json")
    end
  end

  test "preparing refuses dirty worktrees, nonempty unborn workspaces and conflicting task branches" do
    for mutation <- [:dirty, :unborn_nonempty, :branch_conflict, :missing_initial_head] do
      c = context!()
      assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
      preparing_conflict(c, mutation)
      dead!(c)
      assert {:error, :mvp_restart_preparation_changed} = resume(c)
      assert calls(c, :coder) == 0 and calls(c, :publish) == 0
      if mutation in [:dirty, :unborn_nonempty], do: assert(File.read!(Path.join(c.workspace, "retained.txt")) == "retained")
    end
  end

  test "fresh deployment git-init workspace and its frozen unborn preparation both fetch before checkout" do
    for preparing <- [false, :before_fetch, :after_fetch] do
      c = context!()
      File.rename!(c.workspace, c.workspace <> "-seed-retained")
      File.mkdir!(c.workspace)
      Commands.git!(["init"], c.workspace)
      assert {:error, _} = Commands.git(["rev-parse", "--verify", "HEAD"], c.workspace)

      if preparing do
        assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
        branch = "codex/symphony-" <> Path.basename(c.receipt, ".json")
        {:ok, metadata} = ExternalHandoff.encode_git_metadata(git_metadata(c.workspace))

        target =
          if preparing == :after_fetch do
            Commands.git!(["fetch", c.remote, "main"], c.workspace)
            Commands.git!(["rev-parse", "FETCH_HEAD"], c.workspace)
          end

        intent = %{"repository" => %{"repo" => "owner/repo", "base" => "main", "url" => c.remote}, "branch" => branch, "initial_head" => nil, "target" => target, "metadata" => metadata}
        assert :ok = RestartRecovery.preparation(c.receipt, c.workspace, intent)
        dead!(c)
        assert {:ok, "local-draft"} = resume(c)
      else
        assert {:ok, "local-draft"} = Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, options(c))
      end

      data = Receipt.read(c.receipt)
      assert data["restart_recovery"]["preparation"]["initial_head"] == nil
      assert data["restart_recovery"]["preparation"]["target"] == data["base_sha"]
      assert File.read!(Path.join(c.workspace, "source.txt")) == "base"
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    end
  end

  test "preparing after checkout or partial baseline staging is idempotent and preserves artifacts" do
    c = context!()
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    branch = "codex/symphony-" <> Path.basename(c.receipt, ".json")
    head = Commands.git!(["rev-parse", "HEAD"], c.workspace)
    {:ok, metadata} = ExternalHandoff.encode_git_metadata(git_metadata(c.workspace))
    intent = %{"repository" => %{"repo" => "owner/repo", "base" => "main", "url" => c.remote}, "branch" => branch, "initial_head" => head, "target" => head, "metadata" => metadata}
    RestartRecovery.preparation(c.receipt, c.workspace, intent)
    Commands.git!(["checkout", "-b", branch], c.workspace)
    partial = Path.join(c.receipt <> ".evidence", "preparing-old/baseline/partial")
    File.mkdir_p!(Path.dirname(partial))
    File.write!(partial, "preserve incomplete extraction")
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    assert File.read!(partial) == "preserve incomplete extraction"
    assert calls(c, :coder) == 1
  end

  test "unclosed calls for all roles remain uncertain even after model output has been saved" do
    for role <- [:coder, :reviewer, :diagnosis], crash <- [:inside_model, :after_output] do
      c = context!()
      opts = options(c)
      agent = opts[:agent]

      opts =
        Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
          current = role(options)

          if current == role and crash == :inside_model do
            if role == :coder, do: File.write!(Path.join(workspace, "partial.txt"), "partial coder work")
            throw(:controller_crash)
          else
            agent.(workspace, prompt, issue, options)
          end
        end)

      opts = Keyword.put(opts, :now_ms, fn -> stop_after_output(c, role, crash) end)

      c = if role == :diagnosis, do: %{c | settings: %{c.settings | checks: [["false"]]}}, else: c
      assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :controller_crash
      dead!(c)
      before = File.read!(c.receipt)
      used = Receipt.read(c.receipt)["recovery"]["agent_attempts"]

      if crash == :after_output do
        started = List.last(Receipt.read(c.receipt)["recovery"]["events"])
        assert started["role"] == Atom.to_string(role) and started["status"] == "started"
        assert File.exists?(Path.join(started["evidence"], "output.txt"))
      end

      assert {:error, :mvp_restart_model_call_uncertain} = resume(c)
      assert File.read!(c.receipt) == before
      journal = File.read!(c.receipt <> ".restart-blocked.json") |> Jason.decode!()
      assert journal["status"] == "blocked" and journal["reason"] == ":mvp_restart_model_call_uncertain"
      assert journal["receipt_before"] == before
      refute RestartRecovery.eligible?(c.receipt, c.settings)
      refute RestartRecovery.pending?(c.receipt, c.settings)
      assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == used
      if role == :coder and crash == :inside_model, do: assert(File.read!(Path.join(c.workspace, "partial.txt")) == "partial coder work")
      assert calls(c, :publish) == 0
    end
  end

  test "checking interruption reruns every check with the original attempts and elapsed budget" do
    c = interrupted_check!()
    original = Receipt.read(c.receipt)
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    data = Receipt.read(c.receipt)
    assert File.read!(c.trace) == "one\ntwo\n"
    assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    assert data["recovery"]["started_at"] == original["recovery"]["started_at"]
    assert data["rework_count"] == original["rework_count"]
    assert Enum.take(data["recovery"]["events"], length(original["recovery"]["events"])) == original["recovery"]["events"]
  end

  test "the candidate checking transition persists its round and new HEAD checkpoint in one write" do
    c = context!()

    opts =
      Keyword.put(options(c), :on_message, fn
        %{event: :mvp_check_started} -> throw(:checking_crash)
        _ -> :ok
      end)

    writes =
      trace_receipt_writes(fn ->
        assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :checking_crash
      end)

    candidate_writes = for [receipt, "checking", fields] <- writes, receipt == c.receipt and is_binary(fields["candidate_sha"]), do: fields
    assert [transition] = candidate_writes
    sha = transition["candidate_sha"]
    assert List.last(transition["rounds"])["candidate_sha"] == sha
    checkpoint = transition["restart_recovery"]["checkpoint"]
    assert checkpoint["head"] == sha and checkpoint["status"] == "checking"
    assert {:ok, digest} = Executor.workspace_digest(c.workspace)
    assert checkpoint["workspace_sha256"] == digest
    assert Receipt.read(c.receipt)["restart_recovery"]["checkpoint"] == checkpoint
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
  end

  test "confirmed model errors seal failed completion and source checkpoints for every role" do
    for failed_role <- [:coder, :reviewer, :diagnosis] do
      c = context!()
      c = if failed_role == :diagnosis, do: %{c | settings: %{c.settings | checks: [["false"]]}}, else: c
      opts = options(c)
      agent = opts[:agent]

      opts =
        Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
          if role(options) == failed_role do
            count(c, failed_role)
            {:error, :confirmed_model_error}
          else
            agent.(workspace, prompt, issue, options)
          end
        end)

      assert {:error, :confirmed_model_error} = Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)
      data = Receipt.read(c.receipt)
      [started, finished] = Enum.take(data["recovery"]["events"], -2)
      assert started["role"] == Atom.to_string(failed_role)
      assert finished["status"] == "finished" and finished["usage_key"] == started["usage_key"]
      assert finished["completed"] == %{"ok" => false}
      assert finished["outcome"] == inspect({:error, :confirmed_model_error})
      assert {:ok, digest} = Executor.workspace_digest(c.workspace)
      assert finished["source_after_model"] == digest
      assert data["restart_recovery"]["checkpoint"]["workspace_sha256"] == digest
      assert data["recovery"]["agent_attempts"] == if(failed_role == :coder, do: 1, else: 2)
      assert data["status"] == "blocked"
      dead!(c)
      refute RestartRecovery.pending?(c.receipt, c.settings)
      assert calls(c, :publish) == 0
    end
  end

  test "completed coder can finish its commit, but a changed source_after_model is blocked" do
    for changed <- [false, true] do
      c = interrupted_check!()
      # Reconstruct the durable state immediately after the completed coder and before controller commit.
      data = Receipt.read(c.receipt)
      Commands.git!(["reset", "--mixed", data["base_sha"]], c.workspace)
      {:ok, digest} = Executor.workspace_digest(c.workspace)
      checkpoint = data["restart_recovery"]["checkpoint"] |> Map.merge(%{"head" => data["base_sha"], "workspace_sha256" => digest, "status" => "coding"})
      frozen = data["restart_recovery"] |> Map.delete("commit_intent") |> Map.put("checkpoint", checkpoint)
      rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "candidate_sha", nil))
      Receipt.update(c.receipt, "coding", %{"restart_recovery" => frozen, "rounds" => rounds, "candidate_sha" => nil})
      if changed, do: File.write!(Path.join(c.workspace, "candidate.txt"), "changed after model")
      dead!(c)

      if changed do
        assert {:error, :mvp_restart_workspace_changed} = resume(c)
        assert calls(c, :publish) == 0
      else
        assert {:ok, "local-draft"} = resume(c)
        assert calls(c, :coder) == 1
        assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == 2
      end
    end
  end

  test "completed Review approval is reused only after all checks rerun, without another model call" do
    c = context!()
    opts = Keyword.put(options(c), :publish, fn _, _, _, _, _, _, _ -> throw(:before_publish) end)
    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :before_publish
    data = Receipt.read(c.receipt)
    assert data["review"]["approved"]
    old_log = File.read!(Path.join(hd(data["rounds"])["evidence"], "check-1.log"))
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == 2
    assert File.read!(c.trace) == "one\ntwo\none\ntwo\n"
    assert File.read!(Path.join(hd(data["rounds"])["evidence"], "check-1.log")) == old_log
  end

  test "a frozen commit intent reconciles before staging, after staging and after commit without recoding" do
    for phase <- [:mvp_candidate_commit_intent, :mvp_candidate_staged, :mvp_candidate_committed] do
      c = context!()

      opts =
        Keyword.put(options(c), :on_message, fn
          %{event: ^phase} -> throw(:commit_crash)
          _ -> :ok
        end)

      assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :commit_crash
      data = Receipt.read(c.receipt)
      intent = data["restart_recovery"]["commit_intent"]
      assert data["status"] == "coding"
      assert intent["parent"] == data["base_sha"]
      assert intent["branch"] == data["branch"]
      assert is_binary(intent["tree"]) and is_binary(intent["source_index_sha256"])

      assert Commands.git!(["rev-parse", "HEAD"], c.workspace) ==
               if(phase == :mvp_candidate_committed, do: intent["candidate_sha"], else: intent["parent"])

      dead!(c)
      assert {:ok, "local-draft"} = resume(c)
      final = Receipt.read(c.receipt)
      assert final["candidate_sha"] == intent["candidate_sha"]
      assert Commands.git!(["rev-parse", "HEAD^{tree}"], c.workspace) == intent["tree"]
      assert Commands.git!(["rev-list", "--count", "#{intent["parent"]}..HEAD"], c.workspace) == "1"
      assert Commands.git!(["status", "--porcelain"], c.workspace) == ""
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
      assert final["recovery"]["agent_attempts"] == 2
      assert final["recovery"]["started_at"] == data["recovery"]["started_at"]
    end
  end

  test "commit recovery refuses changed source, staged tree, branch, commit payload and unrelated HEAD" do
    for mutation <- [:source, :staged_tree, :branch, :commit_payload, :head] do
      c = context!()

      opts =
        Keyword.put(options(c), :on_message, fn
          %{event: :mvp_candidate_staged} -> throw(:staged_crash)
          _ -> :ok
        end)

      assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :staged_crash
      intent = Receipt.read(c.receipt)["restart_recovery"]["commit_intent"]

      case mutation do
        :source -> File.write!(Path.join(c.workspace, "candidate.txt"), "different source")
        :staged_tree -> Commands.git!(["update-index", "--force-remove", "source.txt"], c.workspace)
        :branch -> Commands.git!(["checkout", "-b", "unrelated"], c.workspace)
        :commit_payload -> File.write!(intent["commit_path"], "unrelated commit bytes")
        :head -> Commands.git!(["commit", "-m", "unrelated commit"], c.workspace)
      end

      dead!(c)
      assert {:error, :mvp_restart_commit_binding_invalid} = resume(c)
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 0 and calls(c, :publish) == 0
    end
  end

  test "a previous round or candidate check attempt budget cannot exhaust a new candidate" do
    for stale <- [:previous_round, :previous_candidate] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)
      manifest = %{"round" => 1, "candidate_sha" => data["candidate_sha"], "attempt" => c.settings.recovery.stage_attempts}

      manifest =
        if stale == :previous_round,
          do: Map.put(manifest, "round", 0),
          else: Map.put(manifest, "candidate_sha", data["base_sha"])

      Receipt.update(c.receipt, "checking", %{"formal_check_evidence" => manifest})
      dead!(c)
      assert {:ok, "local-draft"} = resume(c)
      assert Receipt.read(c.receipt)["formal_check_evidence"]["attempt"] == 1
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1
    end
  end

  test "a commit proof changed after staging cannot update the candidate ref" do
    for mutation <- [:payload, :branch] do
      c = context!()

      callback = fn
        %{event: :mvp_candidate_staged} ->
          intent = Receipt.read(c.receipt)["restart_recovery"]["commit_intent"]

          case mutation do
            :payload -> File.write!(intent["commit_path"], "changed commit message\n", [:append])
            :branch -> Commands.git!(["checkout", "-b", "concurrent-branch"], c.workspace)
          end

        _ ->
          :ok
      end

      opts = Keyword.put(options(c), :on_message, callback)
      assert {:error, _} = Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)
      intent = Receipt.read(c.receipt)["restart_recovery"]["commit_intent"]
      assert Commands.git!(["rev-parse", "refs/heads/" <> intent["branch"]], c.workspace) == intent["parent"]
      assert calls(c, :coder) == 1 and calls(c, :reviewer) == 0 and calls(c, :publish) == 0
    end
  end

  test "three actual checks in a rejected round do not consume the next candidate restart checks" do
    c = context!()
    counter = Path.join(c.root, "check-counter")
    command = "n=0; test ! -f '#{counter}' || n=$(cat '#{counter}'); n=$((n+1)); echo $n > '#{counter}'; test $n -ge 3 && test -f candidate.txt"
    c = %{c | settings: %{c.settings | checks: [["sh", "-c", command]]}}
    opts = options(c, reject_first: true)
    agent = opts[:agent]

    opts =
      Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
        retry_check_diagnosis(c, agent, workspace, prompt, issue, options)
      end)

    opts = Keyword.put(opts, :on_message, &stop_after_second_commit(c, &1))

    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :second_candidate_crash
    before = Receipt.read(c.receipt)
    assert length(before["rounds"]) == 2
    assert before["formal_check_evidence"]["round"] == 1
    assert before["formal_check_evidence"]["attempt"] == 3
    assert hd(before["rounds"])["review"]["approved"] == false
    dead!(c)
    assert {:ok, "local-draft"} = resume(c, reject_first: true)
    final = Receipt.read(c.receipt)
    assert final["formal_check_evidence"]["round"] == 2
    assert final["formal_check_evidence"]["attempt"] == 1
    assert File.read!(counter) == "4\n"
    assert calls(c, :coder) == 2 and calls(c, :reviewer) == 2
    assert final["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 1
  end

  test "completed but not yet recorded Review rejection repairs a new candidate and never polls for approval" do
    c = context!()
    opts = options(c, reject_first: true)
    opts = Keyword.put(opts, :request_fun, fn "POST", _, _, _, _ -> throw(:before_comment) end)
    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :before_comment
    data = Receipt.read(c.receipt)
    # The finished Reviewer event is durable even if record(review) did not happen before the crash.
    rounds = List.update_at(data["rounds"], -1, &Map.drop(&1, ["review", "review_path", "comment"]))
    Receipt.update(c.receipt, "reviewing", %{"rounds" => rounds, "review" => nil, "review_path" => nil})
    rejected = data["candidate_sha"]
    dead!(c)
    assert {:ok, "local-draft"} = resume(c, reject_first: true)
    final = Receipt.read(c.receipt)
    assert length(final["rounds"]) == 2
    assert hd(final["rounds"])["review"]["approved"] == false
    refute final["candidate_sha"] == rejected
    assert calls(c, :coder) == 2 and calls(c, :reviewer) == 2
  end

  test "a confirmed rejection interrupted before repair retains its comment and repairs without reposting" do
    c = context!()
    opts = Keyword.put(options(c, reject_first: true), :request_fun, fn "POST", _, _, _, _ -> throw(:before_comment) end)
    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :before_comment
    data = Receipt.read(c.receipt)
    rounds = List.update_at(data["rounds"], -1, &put_in(&1, ["comment", "id"], 91))
    Receipt.update(c.receipt, "blocked", %{"rounds" => rounds, "reason" => nil})
    dead!(c)
    assert RestartRecovery.eligible?(c.receipt, c.settings)
    opts = Keyword.put(options(c, reject_first: true), :request_fun, fn _, _, _, _, _ -> flunk("confirmed rejection was reposted") end)
    assert {:ok, "local-draft"} = Executor.resume_restart(c.workspace, c.issue, c.settings, models(), c.receipt, opts)
    assert hd(Receipt.read(c.receipt)["rounds"])["comment"]["id"] == 91
    assert calls(c, :coder) == 2
  end

  test "confirmed external Review creates its handoff without repeating review or its comment" do
    c = context!()
    opts = options(c)
    agent = opts[:agent]

    external_agent = fn workspace, prompt, issue, options ->
      if role(options) == :reviewer do
        count(c, :reviewer)
        external = put_in(review(false), ["blockers", Access.at(0), "kind"], "external_condition")
        external = put_in(external, ["blockers", Access.at(0), "external_kind"], "decision")
        {:ok, %{output_text: Jason.encode!(external)}}
      else
        agent.(workspace, prompt, issue, options)
      end
    end

    opts = opts |> Keyword.put(:agent, external_agent) |> Keyword.put(:request_fun, fn "POST", _, _, _, _ -> throw(:comment_sent) end)
    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :comment_sent
    data = Receipt.read(c.receipt)
    rounds = List.update_at(data["rounds"], -1, &put_in(&1, ["comment", "id"], 92))
    Receipt.update(c.receipt, "blocked", %{"rounds" => rounds, "reason" => nil})
    dead!(c)
    opts = Keyword.put(options(c), :request_fun, fn _, _, _, _, _ -> flunk("confirmed external comment was reposted") end)
    result = Executor.resume_restart(c.workspace, c.issue, c.settings, models(), c.receipt, opts)
    assert {:error, {:mvp_awaiting_external, id}} = result
    assert is_binary(id)
    assert Receipt.read(c.receipt)["status"] == "awaiting_external"
    assert hd(Receipt.read(c.receipt)["rounds"])["comment"]["id"] == 92
    assert calls(c, :reviewer) == 1 and calls(c, :publish) == 0
  end

  test "recovering resumes an unstarted or completed diagnosis without resetting spent calls" do
    for completed <- [false, true] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)
      feedback = %{"round" => 1, "feedback" => review(false)}
      events = data["recovery"]["events"] ++ [feedback]

      {events, spent} =
        if completed do
          evidence = Path.join(hd(data["rounds"])["evidence"], "agent-attempt-2")
          File.mkdir!(evidence)
          output = Jason.encode!(%{"action" => "repair_code", "summary" => "repair", "steps" => ["fix candidate"], "external_conditions" => []})
          File.write!(Path.join(evidence, "output.txt"), output)
          start = %{"role" => "diagnosis", "round" => 1, "status" => "started", "usage_key" => "diagnosis_attempt_2", "evidence" => evidence, "stage_attempt" => 1}

          finish = %{
            "status" => "finished",
            "usage_key" => start["usage_key"],
            "source_after_model" => data["restart_recovery"]["checkpoint"]["workspace_sha256"],
            "completed" => %{"ok" => true, "output_text" => output, "output_sha256" => :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)}
          }

          {events ++ [start, finish], 2}
        else
          {events, 1}
        end

      Receipt.update(c.receipt, "recovering", %{"recovery" => Map.merge(data["recovery"], %{"events" => events, "agent_attempts" => spent})})
      dead!(c)
      assert {:ok, "local-draft"} = resume(c)
      assert calls(c, :coder) == 2 and calls(c, :diagnosis) == 0
      assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == spent + 2
    end
  end

  test "completed retry diagnosis advances check attempt two to three and preserves old evidence" do
    c = completed_retry_diagnosis!(2)
    before = Receipt.read(c.receipt)
    second = Path.join(hd(before["rounds"])["evidence"], "check-attempt-2")
    assert File.dir?(second)
    files = evidence_bytes(second)
    dead!(c)
    assert {:ok, "local-draft"} = resume(c)
    data = Receipt.read(c.receipt)
    assert data["formal_check_evidence"]["attempt"] == 3
    assert data["formal_check_evidence"]["evidence"] == Path.join(hd(data["rounds"])["evidence"], "check-attempt-3")
    assert data["candidate_sha"] == before["candidate_sha"]
    assert data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 1
    assert data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert evidence_bytes(second) == files
    assert calls(c, :coder) == 1 and calls(c, :diagnosis) == 2 and calls(c, :reviewer) == 1
  end

  test "completed retry diagnosis at the last check attempt cannot restart its stage budget" do
    c = completed_retry_diagnosis!(3)
    before = Receipt.read(c.receipt)
    evidence = hd(before["rounds"])["evidence"]
    files = evidence_bytes(Path.join(evidence, "check-attempt-2"))
    dead!(c)
    assert {:error, :mvp_recovery_stage_exhausted} = resume(c)
    data = Receipt.read(c.receipt)
    assert data["formal_check_evidence"] == before["formal_check_evidence"]
    assert data["recovery"] == before["recovery"]
    refute File.exists?(Path.join(evidence, "check-attempt-4"))
    assert evidence_bytes(Path.join(evidence, "check-attempt-2")) == files
    assert calls(c, :coder) == 1 and calls(c, :diagnosis) == 3 and calls(c, :reviewer) == 0
  end

  test "only a completed invalid Review permits a fresh independent call; missing completed evidence stops" do
    for evidence_kind <- [:invalid_protocol, :missing_completed_output, :missing_saved_review] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)
      directory = Path.join(hd(data["rounds"])["evidence"], "agent-attempt-2")
      File.mkdir!(directory)
      output = if evidence_kind == :invalid_protocol, do: "invalid JSON", else: Jason.encode!(review(false))
      if evidence_kind != :missing_completed_output, do: File.write!(Path.join(directory, "output.txt"), output)
      start = %{"role" => "reviewer", "round" => 1, "status" => "started", "usage_key" => "reviewer_attempt_2", "evidence" => directory, "stage_attempt" => 1}

      completed =
        if evidence_kind == :invalid_protocol, do: %{"ok" => false}, else: %{"ok" => true, "output_text" => output, "output_sha256" => :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)}

      finish = %{"status" => "finished", "usage_key" => start["usage_key"], "completed" => completed, "outcome" => inspect({:error, :mvp_invalid_review})}
      recovery = Map.merge(data["recovery"], %{"agent_attempts" => 2, "events" => data["recovery"]["events"] ++ [start, finish]})

      rounds =
        if evidence_kind == :missing_saved_review,
          do: List.update_at(data["rounds"], -1, &Map.merge(&1, %{"review" => review(false), "review_path" => Path.join(directory, "missing-review.json")})),
          else: data["rounds"]

      Receipt.update(c.receipt, "reviewing", %{"recovery" => recovery, "rounds" => rounds})
      dead!(c)

      if evidence_kind == :invalid_protocol do
        assert {:ok, "local-draft"} = resume(c)
        assert calls(c, :reviewer) == 1
        assert Receipt.read(c.receipt)["recovery"]["agent_attempts"] == 3
      else
        assert {:error, _} = resume(c)
        assert calls(c, :reviewer) == 0 and calls(c, :publish) == 0
      end
    end
  end

  test "preparing reuses an intact frozen baseline and refuses an incomplete or changed baseline" do
    for intact <- [false, true] do
      c = context!()
      assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
      baseline = Path.join(c.receipt <> ".evidence", "baseline")
      File.mkdir_p!(baseline)
      File.write!(Path.join(baseline, "source.txt"), if(intact, do: "base", else: "changed"))
      dead!(c)

      if intact do
        assert {:ok, "local-draft"} = resume(c)
      else
        assert {:error, :mvp_restart_baseline_changed} = resume(c)
        assert calls(c, :coder) == 0
      end

      assert File.read!(Path.join(baseline, "source.txt")) == if(intact, do: "base", else: "changed")
    end
  end

  test "stale scope, model, source, workspace, metadata and baseline stop before a new call" do
    mutations = ~w(issue models settings source workspace metadata baseline head identity workspace_symlink git_symlink)a

    for mutation <- mutations do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)
      {issue, models, settings} = {c.issue, models(), c.settings}

      {issue, models, settings} =
        case mutation do
          :issue ->
            {%{issue | description: "new scope"}, models, settings}

          :models ->
            {issue, %{models | coder: "different"}, settings}

          :settings ->
            {issue, models, %{settings | checks: [["true"]]}}

          :source ->
            update_restart(c, &Map.put(&1, "source_sha256", "changed"))
            {issue, models, settings}

          :workspace ->
            File.write!(Path.join(c.workspace, "candidate.txt"), "tampered")
            {issue, models, settings}

          :metadata ->
            File.write!(Path.join(c.workspace, ".git/config"), "tampered")
            {issue, models, settings}

          :baseline ->
            File.write!(Path.join(c.receipt <> ".evidence/baseline", "source.txt"), "tampered")
            {issue, models, settings}

          :head ->
            Commands.git!(["checkout", "--detach", data["base_sha"]], c.workspace)
            {issue, models, settings}

          :identity ->
            update_restart(c, &put_in(&1, ["preparation", "identity", "inode"], 0))
            {issue, models, settings}

          :workspace_symlink ->
            File.rename!(c.workspace, c.workspace <> "-retained")
            File.ln_s!(c.workspace <> "-retained", c.workspace)
            {issue, models, settings}

          :git_symlink ->
            git = Path.join(c.workspace, ".git")
            File.rename!(git, git <> "-retained")
            File.ln_s!(git <> "-retained", git)
            {issue, models, settings}
        end

      dead!(c)
      assert {:error, _} = RestartRecovery.resume(c.workspace, issue, settings, models, c.receipt, options(c))
      assert calls(c, :reviewer) == 0 and calls(c, :publish) == 0
    end
  end

  test "restart cannot reset model, round, wall or check-stage budgets" do
    for budget <- [:models, :rounds, :wall, :checks] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)

      case budget do
        :models ->
          Receipt.update(c.receipt, "checking", %{"recovery" => Map.put(data["recovery"], "agent_attempts", c.settings.recovery.max_agent_attempts)})

        :rounds ->
          Receipt.update(c.receipt, "checking", %{"rework_count" => c.settings.recovery.max_rework + 1})

        :wall ->
          Receipt.update(c.receipt, "checking", %{"recovery" => Map.put(data["recovery"], "started_at", "2000-01-01T00:00:00Z")})

        :checks ->
          manifest = %{"attempt" => c.settings.recovery.stage_attempts, "round" => 1, "candidate_sha" => data["candidate_sha"]}
          Receipt.update(c.receipt, "checking", %{"formal_check_evidence" => manifest})
      end

      dead!(c)
      before = Receipt.read(c.receipt)["recovery"]
      assert {:error, reason} = resume(c)
      assert reason in [:mvp_recovery_resource_exhausted, :mvp_recovery_stage_exhausted]
      assert Receipt.read(c.receipt)["recovery"] == before
      assert calls(c, :reviewer) == 0 and calls(c, :publish) == 0
    end
  end

  test "publish_pending uncertainty only GETs Forge and never repeats push or create" do
    for matches <- [0, 1, 2] do
      c = interrupted_check!()
      data = Receipt.read(c.receipt)
      Receipt.update(c.receipt, "publish_pending", %{"base" => "main"})
      dead!(c)

      request = fn method, path, _, _, _ ->
        assert method == "GET" and path == "/repos/owner/repo/pulls"

        pull = %{
          "html_url" => "https://github.com/owner/repo/pull/1",
          "head" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => data["branch"], "sha" => data["candidate_sha"]},
          "base" => %{"repo" => %{"full_name" => "owner/repo"}, "ref" => "main"}
        }

        {:ok, %{status: 200, body: List.duplicate(pull, matches)}}
      end

      result = Executor.resume_restart(c.workspace, c.issue, c.settings, models(), c.receipt, Keyword.put(options(c), :request_fun, request))
      if matches == 1, do: assert({:ok, _} = result), else: assert({:error, :mvp_no_unique_matching_pr} = result)
      assert calls(c, :publish) == 0 and calls(c, :reviewer) == 0
    end
  end

  test "comment_pending uncertainty only GETs the exact durable intent and remains blocked" do
    c = context!()
    opts = options(c, reject_first: true)
    opts = Keyword.put(opts, :request_fun, fn "POST", _, _, _, _ -> throw(:comment_uncertain) end)
    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :comment_uncertain
    comment = List.last(Receipt.read(c.receipt)["rounds"])["comment"]
    dead!(c)
    request = fn "GET", "/repos/owner/repo/issues/42/comments", _, nil, _ -> {:ok, %{status: 200, body: [%{"id" => 19, "body" => comment["body"]}]}} end
    assert {:ok, _} = Executor.resume_restart(c.workspace, c.issue, c.settings, models(), c.receipt, Keyword.put(options(c), :request_fun, request))
    assert Receipt.read(c.receipt)["status"] == "blocked"
    assert calls(c, :coder) == 1 and calls(c, :reviewer) == 1 and calls(c, :publish) == 0
  end

  test "OS lock rejects another holder and releases after return or exception" do
    c = context!()

    assert :ok =
             RestartRecovery.locked(c.receipt, fn ->
               assert {:error, :mvp_restart_active} = RestartRecovery.locked(c.receipt, fn -> flunk("concurrent entry") end)
               :ok
             end)

    assert_raise RuntimeError, "lock test", fn -> RestartRecovery.locked(c.receipt, fn -> raise "lock test" end) end
    assert :ok = RestartRecovery.locked(c.receipt, fn -> :ok end)
  end

  test "runtime false metadata and old terminal tasks remain excluded after enabling restart" do
    c = context!()
    disabled = put_in(c.settings.recovery.resume_on_restart, false)
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, disabled, models())
    assert is_nil(Receipt.read(c.receipt)["restart_recovery"])
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    assert {:error, _} = resume(c)
    refute File.exists?(c.receipt <> ".restart-blocked.json")
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    update_restart(c, &Map.put(&1, "enabled", false))
    dead!(c)
    refute RestartRecovery.eligible?(c.receipt, c.settings)
    assert {:error, _} = resume(c)
  end

  test "unavailable or malformed OS evidence stays unknown, including a denied old PID scan" do
    {:ok, live} = RestartRecovery.owner()
    {pid, ""} = Integer.parse(System.pid())
    {stat, 0} = System.cmd("cat", ["/proc/#{pid}/stat"])

    reader = fn
      :boot -> File.read("/proc/sys/kernel/random/boot_id")
      :machine -> File.read("/etc/machine-id")
      :namespace -> File.read_link("/proc/self/ns/pid")
      {:stat, ^pid} -> {:ok, stat}
      {:stat, _} -> {:error, :eacces}
    end

    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner(fn _ -> {:error, :eacces} end)

    assert {:error, :mvp_restart_owner_unknown} =
             RestartRecovery.owner(fn
               {:stat, _} -> {:ok, "malformed"}
               query -> reader.(query)
             end)

    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner_dead(Map.put(live, "pid", pid + 1), reader)
    assert {:error, :mvp_restart_owner_unknown} = RestartRecovery.owner_dead(live, fn _ -> {:error, :eacces} end)
  end

  test "stops are durable and scoped, including an unavailable journal directory" do
    c = context!()
    assert :ok = RestartRecovery.freeze(c.receipt, c.issue, c.settings, models())
    dead!(c)
    result = {:error, :mvp_restart_model_call_uncertain}
    state = Path.dirname(c.receipt)
    File.chmod!(state, 0o500)

    try do
      assert {:error, {:mvp_restart_stop_write, :eacces}} = RestartRecovery.stop(c.receipt, c.issue, c.settings, result)
    after
      File.chmod!(state, 0o700)
    end

    assert ^result = RestartRecovery.stop(c.receipt, c.issue, c.settings, result)
    original = File.read!(c.receipt <> ".restart-blocked.json")
    assert ^result = RestartRecovery.stop(c.receipt, c.issue, c.settings, result)
    assert File.read!(c.receipt <> ".restart-blocked.json") == original
    assert ^result = RestartRecovery.stop(c.receipt, %{c.issue | id: "another"}, c.settings, result)
    assert {:ok, "done"} = RestartRecovery.stop(c.receipt, c.issue, c.settings, {:ok, "done"})
    refute File.exists?(Receipt.path(c.settings, %{c.issue | id: "another"}) <> ".restart-blocked.json")
    assert {:error, _} = RestartRecovery.resume(c.workspace, c.issue, c.settings, models(), c.receipt)
    assert {:error, _} = Executor.resume_restart(c.workspace, c.issue, c.settings, models(), c.receipt)
  end

  test "missing flock and an unresponsive lock helper both fail closed" do
    c = context!()
    path = System.get_env("PATH")
    tools = Path.join(c.root, "tools")
    File.mkdir!(tools)
    System.put_env("PATH", tools)

    try do
      assert {:error, :mvp_restart_lock_unavailable} = RestartRecovery.locked(c.receipt, fn -> flunk("missing flock") end)
      File.write!(Path.join(tools, "flock"), "#!/bin/sh\n/bin/sleep 6\n")
      File.chmod!(Path.join(tools, "flock"), 0o700)
      assert {:error, :mvp_restart_lock_unavailable} = RestartRecovery.locked(c.receipt, fn -> flunk("unconfirmed lock") end)
    after
      System.put_env("PATH", path)
    end
  end

  defp trace_receipt_writes(fun) do
    tracer = spawn_link(fn -> collect_receipt_writes([]) end)
    :erlang.trace_pattern({Receipt, :update, 3}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Receipt, :update, 3}, false, [])
    end

    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _, ^ref} -> :ok
    after
      5000 -> flunk("receipt trace was not delivered")
    end

    send(tracer, {:writes, self()})

    receive do
      {:receipt_writes, writes} -> writes
    after
      5000 -> flunk("receipt trace was not collected")
    end
  end

  defp collect_receipt_writes(writes) do
    receive do
      {:trace, _, :call, {Receipt, :update, args}} -> collect_receipt_writes([args | writes])
      {:writes, caller} -> send(caller, {:receipt_writes, Enum.reverse(writes)})
    end
  end

  defp completed_retry_diagnosis!(attempt) do
    c = context!()
    counter = Path.join(c.root, "check-counter")
    command = "n=0; test ! -f '#{counter}' || n=$(cat '#{counter}'); n=$((n+1)); echo $n > '#{counter}'; test $n -gt #{attempt}"
    c = %{c | settings: %{c.settings | checks: [["sh", "-c", command]]}}
    next = Path.join(c.receipt <> ".evidence/round-1", "check-attempt-#{attempt + 1}")

    if attempt == 2 do
      File.mkdir_p!(next)
      File.write!(Path.join(next, "retained.txt"), "existing next-check evidence")
    end

    opts = options(c)
    agent = opts[:agent]

    opts =
      Keyword.put(opts, :agent, fn workspace, prompt, issue, options ->
        retry_check_diagnosis(c, agent, workspace, prompt, issue, options)
      end)

    expected = if attempt == 2, do: :eexist, else: :mvp_recovery_stage_exhausted
    assert {:error, ^expected} = Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)
    data = Receipt.read(c.receipt)
    assert data["formal_check_evidence"]["attempt"] == attempt
    assert List.last(data["recovery"]["events"])["completed"]["ok"]
    assert File.read!(counter) == "#{attempt}\n"
    if attempt == 2, do: File.rename!(next, Path.join(c.root, "retained-next-check"))

    # Model the crash immediately after the real completed diagnosis, before the terminal wrapper.
    # The old retry directory is retained elsewhere; all completed check and model evidence stays intact.
    Receipt.update(c.receipt, "recovering", %{"reason" => nil})
    c
  end

  defp evidence_bytes(directory) do
    directory |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Map.new(&{&1, File.read!(&1)})
  end

  defp stop_after_second_commit(c, %{event: :mvp_candidate_committed}) do
    if List.last(Receipt.read(c.receipt)["rounds"])["round"] == 2, do: throw(:second_candidate_crash)
    :ok
  end

  defp stop_after_second_commit(_c, _message), do: :ok

  defp retry_check_diagnosis(c, agent, workspace, prompt, issue, options) do
    if role(options) == :diagnosis do
      count(c, :diagnosis)
      advice = %{"action" => "retry_stage", "summary" => "temporary check failure", "steps" => ["retry trusted checks"], "external_conditions" => []}
      {:ok, %{output_text: Jason.encode!(advice)}}
    else
      agent.(workspace, prompt, issue, options)
    end
  end

  defp stop_after_output(c, role, :after_output) do
    events = get_in(Receipt.read(c.receipt), ["recovery", "events"]) || []
    last = List.last(events) || %{}

    if last["role"] == Atom.to_string(role) and last["status"] == "started" and
         File.exists?(Path.join(last["evidence"], "output.txt")),
       do: throw(:controller_crash)

    System.system_time(:millisecond)
  end

  defp stop_after_output(_c, _role, :inside_model), do: System.system_time(:millisecond)

  defp preparing_conflict(c, mutation) when mutation in [:dirty, :unborn_nonempty] do
    if mutation == :unborn_nonempty do
      File.rename!(c.workspace, c.workspace <> "-retained")
      File.mkdir!(c.workspace)
      Commands.git!(["init"], c.workspace)
    end

    File.write!(Path.join(c.workspace, "retained.txt"), "retained")
  end

  defp preparing_conflict(c, mutation) do
    head = Commands.git!(["rev-parse", "HEAD"], c.workspace)
    branch = "codex/symphony-" <> Path.basename(c.receipt, ".json")

    if mutation == :branch_conflict do
      Commands.git!(["checkout", "-b", branch], c.workspace)
      Commands.git!(["commit", "--allow-empty", "-m", "unrelated"], c.workspace)
      Commands.git!(["checkout", "main"], c.workspace)
    else
      File.rename!(c.workspace, c.workspace <> "-retained")
      File.mkdir!(c.workspace)
      Commands.git!(["init"], c.workspace)
    end

    {:ok, metadata} = ExternalHandoff.encode_git_metadata(git_metadata(c.workspace))
    intent = %{"repository" => %{"repo" => "owner/repo", "base" => "main", "url" => c.remote}, "branch" => branch, "initial_head" => head, "target" => head, "metadata" => metadata}
    RestartRecovery.preparation(c.receipt, c.workspace, intent)
  end

  defp context! do
    root = Path.join(System.tmp_dir!(), "restart-recovery-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-42")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base")
    Commands.git!(["add", "."], workspace)
    Commands.git!(["commit", "-m", "base"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["push", remote, "main"], workspace)

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Create candidate",
      description: "candidate exists",
      native_ref: %{"repo" => "owner/repo", "number" => 42},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)
    {:ok, policy} = Recovery.settings(%{"enabled" => true, "resume_on_restart" => true, "max_elapsed_ms" => 120_000, "max_rework" => 3})
    trace = Path.join(root, "checks")
    checks = for word <- ~w(one two), do: ["sh", "-c", "test -f candidate.txt && echo #{word} >> '#{trace}'"]

    settings = %{
      checks: checks,
      check_timeout_ms: 5000,
      max_rework: 0,
      recovery: policy,
      ready_label: "ready",
      allowed_actors: ["owner"],
      allowed_models: ["coder", "reviewer"],
      sandbox: %{enabled: false},
      execution_readiness: %{enabled: true, required_backend: "vm"},
      execution_workspace_root: root,
      state_dir: Path.dirname(receipt)
    }

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      workspace: workspace,
      remote: remote,
      issue: issue,
      receipt: receipt,
      settings: settings,
      trace: trace,
      key: make_ref()
    }
  end

  defp interrupted_check! do
    c = context!()

    opts =
      Keyword.put(options(c), :on_message, fn
        %{event: :mvp_check_started} -> throw(:checking_crash)
        _ -> :ok
      end)

    assert catch_throw(Executor.run(c.workspace, c.issue, c.settings, models(), c.receipt, opts)) == :checking_crash
    c
  end

  defp models, do: %{coder: "coder", reviewer: "reviewer", services: nil}
  defp resume(c, behavior \\ []), do: RestartRecovery.resume(c.workspace, c.issue, c.settings, models(), c.receipt, options(c, behavior))
  defp calls(c, role), do: Process.get({c.key, role}, 0)
  defp count(c, role), do: Process.put({c.key, role}, calls(c, role) + 1)
  defp role(opts), do: if(opts[:output_schema] == Recovery.schema(), do: :diagnosis, else: if(opts[:read_only], do: :reviewer, else: :coder))

  defp options(c, behavior \\ []) do
    [
      repository: fn _, _ -> {:ok, %{repo: "owner/repo", base: "main", url: c.remote}} end,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "synthetic"}},
      agent: fn workspace, _, _, opts ->
        role = role(opts)
        count(c, role)

        case role do
          :coder ->
            File.write!(Path.join(workspace, "candidate.txt"), "candidate #{calls(c, :coder)}")
            {:ok, %{output_text: "done"}}

          :reviewer ->
            {:ok, %{output_text: Jason.encode!(review(not (behavior[:reject_first] == true and calls(c, :reviewer) == 1)))}}

          :diagnosis ->
            {:ok, %{output_text: Jason.encode!(%{"action" => "repair_code", "summary" => "repair", "steps" => ["repair source"], "external_conditions" => []})}}
        end
      end,
      publish: fn _, _, _, _, _, _, _ ->
        count(c, :publish)
        {:ok, "local-draft"}
      end,
      request_fun: fn "POST", _, _, body, _ -> {:ok, %{status: 201, body: %{"id" => 1, "body" => body["body"]}}} end
    ]
  end

  defp review(approved) do
    %{
      "approved" => approved,
      "summary" => "review",
      "criteria" => [
        %{"acceptance" => "candidate exists", "tests" => ["candidate check"], "assertion_strength" => "checks content", "failure_sensitivity" => "missing content fails", "adequate" => approved}
      ],
      "blockers" =>
        if(approved,
          do: [],
          else: [
            %{"acceptance" => "candidate exists", "kind" => "code_defect", "external_kind" => "not_applicable", "reason" => "fix candidate", "required_evidence" => "regression", "handoff" => "coder"}
          ]
        )
    }
  end

  defp update_restart(c, fun), do: Receipt.update(c.receipt, Receipt.read(c.receipt)["status"], %{"restart_recovery" => fun.(Receipt.read(c.receipt)["restart_recovery"])})

  defp dead!(c) do
    # A real subprocess supplies its own PID/starttime, then exits before recovery checks it.
    {stat, 0} = System.cmd("cat", ["/proc/self/stat"])
    [pid, fields] = Regex.run(~r/\A(\d+) \(.*\) (.*)\z/s, String.trim(stat), capture: :all_but_first)
    start = fields |> String.split() |> Enum.at(19)
    {:ok, current} = RestartRecovery.owner()
    owner = Map.merge(current, %{"pid" => String.to_integer(pid), "starttime" => start})
    update_restart(c, &Map.put(&1, "owner", owner))
  end

  defp git_metadata(workspace), do: Map.new(~w(.git/config .git/info/attributes .git/info/exclude), &{&1, File.read(Path.join(workspace, &1))})
end
