defmodule SymphonyElixir.Mvp.InterruptedResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Attempts, Commands, Executor, InterruptedCoder, Receipt, Recovery}

  @old_boot "00000000-0000-0000-0000-000000000001"
  @new_boot "00000000-0000-0000-0000-000000000002"
  @url "https://github.com/owner/repo/pull/42"

  test "interrupted diagnosed check repair preserves the round, evidence, usage and budget and reruns all gates" do
    {context, auth, before} = interrupted!()
    raw = File.read!(context.receipt)
    files = prior_files(context)
    assert {:ok, @url} = Executor.resume_interrupted(context, digest(raw), auth)
    after_data = Receipt.read(context.receipt)
    assert after_data["recovery"]["started_at"] == before["recovery"]["started_at"]
    assert after_data["recovery"]["policy"] == before["recovery"]["policy"]
    assert after_data["recovery"]["agent_attempts"] == before["recovery"]["agent_attempts"] + 2
    assert after_data["rework_count"] == before["rework_count"]
    assert length(after_data["rounds"]) == length(before["rounds"])
    assert hd(after_data["rounds"]) == hd(before["rounds"])
    assert Enum.take(after_data["recovery"]["events"], length(before["recovery"]["events"])) == before["recovery"]["events"]
    event = Enum.at(after_data["recovery"]["events"], length(before["recovery"]["events"]))
    assert event["kind"] == "operator_interrupted_coder_resume"
    assert event["previous_boot_id"] == @old_boot
    assert event["current_boot_id"] == @new_boot
    assert event["attempt"] == 3
    resumed_start = Enum.find(after_data["recovery"]["events"], &(&1["attempt"] == 4))
    reviewer_start = Enum.find(after_data["recovery"]["events"], &(&1["attempt"] == 5))
    assert resumed_start["stage_attempt"] == 2
    assert reviewer_start["stage_attempt"] == 1
    assert File.read!(Path.join(context.workspace, "candidate.txt")) == "completed from partial"
    assert Process.get(:resumed_prompt) =~ "repair_code"
    assert Process.get(:resumed_prompt) =~ "Recovered original diff"
    assert Process.get(:reviewed_sha) == after_data["candidate_sha"]
    refute Process.get(:reviewed_sha) == before["candidate_sha"]
    assert Process.get(:checked) == [1, 2, 3]
    assert Map.new(files, fn {path, _} -> {path, File.read!(path)} end) == files
    operation = Path.join([context.evidence, "operator-rechecks", auth["id"]])
    assert File.read!(Path.join(operation, "receipt-before.json")) == raw
    audit = File.read!(Path.join(operation, "authorization.json")) |> Jason.decode!()
    assert audit["interruption_evidence_digest"] == auth["interruption_evidence_digest"]
    assert audit["interrupted_owner"]["previous_pid"] == 40_124
    assert File.regular?(Path.join(operation, "completion.json"))
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_interrupted(context, digest(raw), auth)
  end

  test "stale digest, scope, models, checks, policy, head, metadata and baseline fail before any write" do
    {context, auth, _before} = interrupted!()
    raw = File.read!(context.receipt)
    expected = digest(raw)
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_interrupted(context, "stale", auth)

    for changed <- [
          put_in(context.models.coder, "different"),
          put_in(context.settings.checks, [["false"]]),
          put_in(context.settings.recovery.max_agent_attempts, 70),
          %{context | base: String.duplicate("0", 40)}
        ] do
      assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_interrupted(changed, expected, auth)
    end

    changed_scope = put_in(context.issue.title, "changed")
    assert {:error, :mvp_recovery_scope_mismatch} = Executor.resume_interrupted(changed_scope, expected, auth)
    bad_digest = %{auth | "workspace_digest" => "wrong"}
    bad_digest_result = Executor.resume_interrupted(context, expected, bad_digest)
    assert {:error, :mvp_recovery_workspace_digest_mismatch} = bad_digest_result
    metadata_path = Path.join(context.workspace, ".git/config")
    original = File.read!(metadata_path)
    File.write!(metadata_path, original <> "\n# changed\n")
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_interrupted(context, expected, auth)
    File.write!(metadata_path, original)
    baseline_file = Path.join(context.evidence, "baseline/source.txt")
    File.write!(baseline_file, "tampered")
    assert {:error, :mvp_resume_binding_mismatch} = Executor.resume_interrupted(context, expected, auth)
    assert File.read!(context.receipt) == raw
    refute File.exists?(Path.join(context.evidence, "operator-rechecks"))
  end

  test "resource limits and audit locks cannot be bypassed by an interruption authorization" do
    {context, auth, before} = interrupted!()
    raw = File.read!(context.receipt)
    disabled = %{settings: %{recovery: %{enabled: false}}}
    assert {:error, :mvp_recovery_not_enabled} = Executor.resume_interrupted(disabled, "unused", %{})

    for field <- ["wall_budget_extension_ms", "execution_sandbox_change"] do
      changed_auth = Map.put(auth, field, 1)
      changed_result = Executor.resume_interrupted(context, digest(raw), changed_auth)
      assert {:error, :mvp_interruption_resource_change} = changed_result
    end

    changed_sandbox = put_in(context.settings.sandbox, %{enabled: true})
    assert {:error, :mvp_recovery_sandbox_mismatch} = Executor.resume_interrupted(changed_sandbox, digest(raw), auth)
    {:ok, start, _} = DateTime.from_iso8601(before["recovery"]["started_at"])
    expired = DateTime.to_unix(start, :millisecond) + context.settings.recovery.max_elapsed_ms
    exhausted = %{context | opts: Keyword.put(context.opts, :now_ms, fn -> expired end)}
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_interrupted(exhausted, digest(raw), auth)
    limited = put_in(before, ["recovery", "agent_attempts"], context.settings.recovery.max_agent_attempts)
    File.write!(context.receipt, Jason.encode!(limited))
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_interrupted(context, digest(File.read!(context.receipt)), auth)
    File.write!(context.receipt, raw)
    lock = Path.join(context.evidence, "operator-recheck.lock")
    File.write!(lock, "active")
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = Executor.resume_interrupted(context, digest(raw), auth)
    File.rm!(lock)
    File.mkdir_p!(Path.join([context.evidence, "operator-rechecks", auth["id"]]))
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = Executor.resume_interrupted(context, digest(raw), auth)
    assert File.read!(context.receipt) == raw
  end

  test "resumed coder retains consumed stage attempts and cannot retry beyond the frozen stage cap" do
    {context, auth, before} = interrupted!()
    events = List.update_at(before["recovery"]["events"], -1, &Map.put(&1, "stage_attempt", 2))
    before = put_in(before, ["recovery", "events"], events)
    File.write!(context.receipt, Jason.encode!(before))
    agent = fn _, _, _, _ -> {:error, {:port_exit, 1}} end
    resumed = %{context | opts: Keyword.put(context.opts, :agent, agent)}
    assert {:error, {:port_exit, 1}} = Executor.resume_interrupted(resumed, digest(File.read!(context.receipt)), auth)
    data = Receipt.read(context.receipt)
    assert data["recovery"]["agent_attempts"] == 4
    assert Enum.find(data["recovery"]["events"], &(&1["attempt"] == 4))["stage_attempt"] == 3
    assert data["status"] == "blocked"
    assert is_nil(data["review"])

    exhausted = put_in(before, ["recovery", "events"], List.update_at(events, -1, &Map.put(&1, "stage_attempt", 3)))
    File.write!(context.receipt, Jason.encode!(exhausted))
    assert {:error, :mvp_recovery_resource_exhausted} = Executor.resume_interrupted(context, digest(File.read!(context.receipt)), auth)
    invalid = Map.put(context, :coder_stage_attempt, 4)
    assert {:error, :mvp_recovery_resource_exhausted} = Attempts.run(invalid, :coder, "unused", fn -> :ok end)
  end

  test "all bindings are repeated under the audit lock and rejected continuation completes an honest audit" do
    {context, auth, _before} = interrupted!()
    raw = File.read!(context.receipt)
    Process.put(:owner_observations, 0)

    boot = fn ->
      count = Process.get(:owner_observations) + 1
      Process.put(:owner_observations, count)
      {:ok, if(count == 1, do: @new_boot, else: @old_boot)}
    end

    changing = %{context | opts: Keyword.put(context.opts, :interruption_boot, boot)}
    assert {:error, :mvp_interruption_owner_mismatch} = Executor.resume_interrupted(changing, digest(raw), auth)
    assert File.read!(context.receipt) == raw
    operation = Path.join([context.evidence, "operator-rechecks", auth["id"]])
    completion = File.read!(Path.join(operation, "completion.json")) |> Jason.decode!()
    assert completion["result"] == "{:error, :mvp_interruption_owner_mismatch}"
    assert Process.get(:coder_calls) == 2
  end

  test "dirty workspace changed between approval and lock cannot dispatch a coder" do
    {context, auth, _before} = interrupted!()
    raw = File.read!(context.receipt)

    owner = fn checked ->
      File.write!(Path.join(checked.workspace, "candidate.txt"), "changed during owner observation")
      :ok
    end

    changing = %{context | opts: Keyword.put(context.opts, :interruption_active_owner, owner)}
    assert {:error, :mvp_interruption_evidence_changed} = Executor.resume_interrupted(changing, digest(raw), auth)
    assert File.read!(context.receipt) == raw
    assert Process.get(:coder_calls) == 2
  end

  test "complete diagnosis and failed checks are bound to the unfinished coder and exact evidence bytes" do
    {context, auth, before} = interrupted!()
    assert {:ok, _, _} = InterruptedCoder.evidence(context, before)
    assert {:error, :mvp_interruption_evidence_mismatch} = InterruptedCoder.evidence(context, %{})
    assert {:error, :mvp_interruption_evidence_mismatch} = Executor.resume_interrupted(context, digest(File.read!(context.receipt)), %{auth | "interruption_evidence_digest" => "wrong"})
    files = prior_files(context)

    for {path, bytes} <- files do
      File.rm!(path)
      assert {:error, :mvp_interruption_evidence_mismatch} = InterruptedCoder.evidence(context, before)
      File.write!(path, bytes)
    end

    last_path = Path.join(List.last(before["rounds"])["evidence"], "agent-attempt-3/output.txt")
    File.write!(last_path, "a completed attempt cannot be interrupted")
    assert {:error, :mvp_interruption_evidence_mismatch} = InterruptedCoder.evidence(context, before)
    File.rm!(last_path)

    for mutate <- [
          fn data -> put_in(data, ["recovery", "events"], []) end,
          fn data -> put_in(data, ["rounds"], List.update_at(data["rounds"], 0, &Map.put(&1, "review", %{"approved" => false}))) end,
          fn data -> put_in(data, ["rounds"], List.update_at(data["rounds"], 0, &put_in(&1, ["check_failure", "index"], 99))) end,
          fn data -> put_in(data, ["recovery", "events"], List.update_at(data["recovery"]["events"], 0, &Map.put(&1, "usage_key", "wrong"))) end,
          fn data -> put_in(data, ["recovery", "events"], List.update_at(data["recovery"]["events"], 1, &Map.put(&1, "usage_key", "wrong"))) end,
          fn data -> put_in(data, ["recovery", "events"], List.update_at(data["recovery"]["events"], 1, &Map.put(&1, "outcome", "{:error, :invalid}"))) end
        ] do
      assert {:error, :mvp_interruption_evidence_mismatch} = InterruptedCoder.evidence(context, mutate.(before))
    end

    path = Path.join(context.evidence, "round-1/check-1.json")
    original = File.read!(path)
    File.write!(path, Jason.encode!(%{"index" => 1, "argv" => ["false"]}))
    assert {:error, :mvp_interruption_evidence_mismatch} = InterruptedCoder.evidence(context, before)
    File.write!(path, original)
    log = Path.join(context.evidence, "round-1/check-1.log")
    File.write!(log, "tampered log")
    assert {:error, :mvp_interruption_evidence_mismatch} = Executor.resume_interrupted(context, digest(File.read!(context.receipt)), auth)
  end

  test "owner evidence rejects arbitrary old boot, missing snapshot, wrong binding, same boot and live owner" do
    {context, auth, before} = interrupted!()
    assert {:ok, _} = InterruptedCoder.owner(context, before, auth)
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(%{context | interruption_owner_record: %{}}, before, auth)

    for changed <- [
          %{auth | "previous_owner" => %{"path" => "/arbitrary", "sha256" => "wrong"}},
          Map.delete(auth, "task_owner"),
          put_in(auth, ["task_owner", "sha256"], "wrong")
        ] do
      assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(context, before, changed)
    end

    same_boot = %{context | opts: Keyword.put(context.opts, :interruption_boot, fn -> {:ok, @old_boot} end)}
    live_owner = %{context | opts: Keyword.put(context.opts, :interruption_active_owner, fn _ -> {:error, :active} end)}
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(same_boot, before, auth)
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(live_owner, before, auth)
    task_path = context.interruption_owner_record.task
    old = File.read!(task_path)

    for change <- [
          fn data -> Map.put(data, "pid", 777) end,
          fn data -> Map.put(data, "state", "malformed") end,
          fn data -> Map.put(data, "gh7_receipts", []) end,
          fn data -> put_in(data, ["gh7_receipts"], List.update_at(data["gh7_receipts"], 0, &put_in(&1, ["receipt", "models", "coder"], "wrong"))) end
        ] do
      File.write!(task_path, Jason.encode!(change.(Jason.decode!(old))))
      changed_auth = put_in(auth, ["task_owner", "sha256"], digest(File.read!(task_path)))
      assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(context, before, changed_auth)
    end

    File.write!(task_path, old)
    File.rm!(task_path)
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(context, before, auth)
  end

  test "default ownership observer requires a live loopback state and detects running and retrying tasks" do
    {context, auth, before} = interrupted!()
    context = %{context | opts: Keyword.drop(context.opts, [:interruption_boot, :interruption_active_owner])}
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(context, before, auth)

    for state <- [%{"running" => [], "retrying" => []}, %{"running" => [%{"issue_id" => "42"}], "retrying" => []}, %{"running" => [], "retrying" => [%{"issue_id" => "42"}]}, %{}] do
      url = status_server(state)
      observed = Map.put(context, :interruption_status_url, url)

      if state == %{"running" => [], "retrying" => []} do
        assert {:ok, owner} = InterruptedCoder.owner(observed, before, auth)
        refute owner["current_boot_id"] == @old_boot
      else
        assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(observed, before, auth)
      end
    end
  end

  test "process ownership scan tolerates vanished processes and blocks unverifiable current processes" do
    {context, auth, before} = interrupted!()
    proc_root = Path.join(Path.dirname(context.workspace), "proc-fixture")
    process = Path.join(proc_root, "123")
    File.mkdir_p!(process)
    opts = Keyword.delete(context.opts, :interruption_active_owner)
    opts = Keyword.put(opts, :interruption_proc_root, proc_root)
    state = %{"running" => [], "retrying" => []}
    observed = Map.merge(context, %{opts: opts, interruption_status_url: status_server(state)})
    assert {:ok, _} = InterruptedCoder.owner(observed, before, auth)

    File.mkdir_p!(Path.join(process, "cmdline"))
    blocked = Map.put(observed, :interruption_status_url, status_server(state))
    assert {:error, :mvp_interruption_owner_mismatch} = InterruptedCoder.owner(blocked, before, auth)
  end

  defp interrupted! do
    root = Path.join(System.tmp_dir!(), "mvp-interrupted-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    Commands.git!(["init", "--bare", remote], root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base source\n")
    Commands.git!(["add", "."], workspace)
    Commands.git!(["commit", "-m", "initial"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["remote", "add", "origin", remote], workspace)
    Commands.git!(["push", "--set-upstream", "origin", "main"], workspace)

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Finish check repair",
      description: "Preserve the incomplete repair",
      native_ref: %{"repo" => "owner/repo", "number" => 42},
      state: "open"
    }

    {:ok, receipt} = Receipt.claim(%{state_dir: Path.join(root, "state")}, issue)
    repository = %{repo: "owner/repo", base: "main", url: remote}
    {:ok, policy} = Recovery.settings(%{"enabled" => true})

    check_code =
      "import pathlib,sys; sys.exit(0 if pathlib.Path('candidate.txt').read_text() " <>
        "== 'completed from partial' else 1)"

    check = ["python3", "-c", check_code]
    settings = %{checks: [["true"], ["true"], check], check_timeout_ms: 10_000, max_rework: 5}
    settings = Map.merge(settings, %{recovery: policy, sandbox: %{enabled: false}})
    models = %{coder: "gpt-6.1-sol", reviewer: "gpt-6.1-sol"}
    Process.put(:coder_calls, 0)
    Process.put(:checked, [])

    agent = fn target, prompt, _, opts -> mock_agent(target, prompt, opts, receipt) end

    opts = [
      repository: fn _, _ -> {:ok, repository} end,
      tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}},
      agent: agent,
      publish: fn _, _, _, _, _, _, _ -> {:ok, @url} end,
      interruption_boot: fn -> {:ok, @new_boot} end,
      interruption_active_owner: fn _ -> :ok end
    ]

    assert catch_throw(Executor.run(workspace, issue, settings, models, receipt, opts)) == :boot_changed
    before = Receipt.read(receipt)
    assert before["status"] == "coding"
    assert before["recovery"]["agent_attempts"] == 3
    evidence = receipt <> ".evidence"

    context = %{
      workspace: workspace,
      receipt: receipt,
      issue: issue,
      repository: repository,
      settings: settings,
      models: models,
      opts: opts,
      base: before["base_sha"],
      branch: before["branch"],
      evidence: evidence,
      limit: 20,
      metadata: Map.new([".git/config", ".git/info/attributes", ".git/info/exclude"], &{&1, File.read(Path.join(workspace, &1))}),
      baseline_digest: tree_digest(Path.join(evidence, "baseline"))
    }

    workflow = Path.join(root, "WORKFLOW.md")
    install = Path.join(root, "release")
    watchdog_path = Path.join(root, "watchdog.before.json")
    task_path = Path.join(root, "task-owner.json")

    owner = %{
      "pid" => 40_124,
      "boot_id" => @old_boot,
      "start_ticks" => "12345",
      "install" => install,
      "version" => String.duplicate("a", 40),
      "workflow" => workflow,
      "cmdline" => [Path.join(install, "bin/symphony"), workflow]
    }

    File.write!(watchdog_path, Jason.encode!(%{"process" => owner, "service" => workflow}))

    File.write!(
      task_path,
      Jason.encode!(%{
        "pid" => 40_124,
        "state" => %{"running" => [%{"issue_id" => issue.id, "workspace_path" => workspace}]},
        "gh7_receipts" => [%{"path" => receipt, "receipt" => Process.get(:first_receipt)}]
      })
    )

    on_message = fn
      %{event: :mvp_check_started, message: message} -> Process.put(:checked, Process.get(:checked) ++ [message |> String.split() |> List.last() |> String.to_integer()])
      _ -> :ok
    end

    context = context |> Map.put(:interruption_owner_record, %{watchdog: watchdog_path, task: task_path, workflow: workflow}) |> Map.put(:opts, Keyword.put(opts, :on_message, on_message))
    {:ok, workspace_sha} = Executor.workspace_digest(workspace)
    {:ok, proof, _} = InterruptedCoder.evidence(context, before)

    auth = %{
      "id" => "interrupted-resume",
      "authorization" => "Explicit authorization to continue this interrupted task",
      "runtime_version" => String.duplicate("b", 40),
      "command" => ["operator", "resume-interrupted"],
      "diagnostic" => "Recovered original diff",
      "legacy_closures" => [],
      "predecessor" => nil,
      "workspace_digest" => workspace_sha,
      "interruption_evidence_digest" => digest(Jason.encode!(proof)),
      "previous_owner" => %{"path" => watchdog_path, "sha256" => digest(File.read!(watchdog_path))},
      "task_owner" => %{"path" => task_path, "sha256" => digest(File.read!(task_path))}
    }

    {context, auth, before}
  end

  defp mock_agent(target, prompt, opts, receipt) do
    case opts[:output_schema] do
      %{"required" => required} -> mock_readonly_agent(required, target)
      nil -> mock_coder(target, prompt, receipt)
    end
  end

  defp mock_readonly_agent(required, target) do
    if "action" in required do
      {:ok,
       %{
         output_text:
           Jason.encode!(%{
             "action" => "repair_code",
             "summary" => "Fix check defect",
             "steps" => ["Continue the partial repair"],
             "external_conditions" => []
           })
       }}
    else
      Process.put(:reviewed_sha, Commands.git!(["rev-parse", "HEAD"], target))

      {:ok,
       %{
         output_text:
           Jason.encode!(%{
             "approved" => true,
             "summary" => "All frozen acceptance passed",
             "criteria" => [
               %{
                 "acceptance" => "Preserve the incomplete repair",
                 "adequate" => true,
                 "tests" => ["All three frozen checks"],
                 "assertion_strength" => "Checks completed partial value",
                 "failure_sensitivity" => "Initial and partial values fail"
               }
             ],
             "blockers" => []
           })
       }}
    end
  end

  defp mock_coder(target, prompt, receipt) do
    call = Process.get(:coder_calls) + 1
    Process.put(:coder_calls, call)

    case call do
      1 ->
        Process.put(:first_receipt, Receipt.read(receipt))
        File.write!(Path.join(target, "candidate.txt"), "initial")
        {:ok, %{output_text: "Initial implementation"}}

      2 ->
        File.write!(Path.join(target, "candidate.txt"), "partial")
        throw(:boot_changed)

      _ ->
        assert File.read!(Path.join(target, "candidate.txt")) == "partial"
        Process.put(:resumed_prompt, prompt)
        File.write!(Path.join(target, "candidate.txt"), "completed from partial")
        {:ok, %{output_text: "Finished existing partial repair"}}
    end
  end

  defp prior_files(context) do
    Path.wildcard(Path.join(context.evidence, "round-*/**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp tree_digest(root) do
    Path.wildcard(Path.join(root, "**/*"), match_dot: true)
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

  defp status_server(state) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    body = Jason.encode!(state)

    spawn(fn ->
      {:ok, client} = :gen_tcp.accept(socket)
      {:ok, _} = :gen_tcp.recv(client, 0, 5_000)
      :ok = :gen_tcp.send(client, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body)
      :gen_tcp.close(client)
      :gen_tcp.close(socket)
    end)

    "http://127.0.0.1:#{port}/api/v1/state"
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
