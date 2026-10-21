defmodule SymphonyElixir.Mvp.ModelServicesRetentionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.ModelServices

  @old_time 1_600_000_000

  setup do
    root = Path.join(System.tmp_dir!(), "model-services-retention-#{System.unique_integer([:positive])}")
    state = Path.join([root, "runtime", "state"])
    sandboxes = Path.join([root, "runtime", "sandboxes"])
    File.mkdir_p!(state)
    File.mkdir_p!(sandboxes)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, state: state, sandboxes: sandboxes}
  end

  test "VM allocation preserves all migrated transcripts after more than fifty new sessions", ctx do
    originals =
      for number <- 1..55 do
        run = run!(ctx.sandboxes, "migrated-#{number}")
        transcript = Path.join([run, "codex-home", "sessions", "original.jsonl"])
        File.mkdir_p!(Path.dirname(transcript))
        bytes = Jason.encode!(%{"session" => number, "message" => "migrated history"}) <> "\n"
        File.write!(transcript, bytes)
        stamp_tree!(run, @old_time + number)
        {transcript, bytes}
      end

    settings = %{
      state_dir: ctx.state,
      sandbox: %{enabled: false},
      execution_readiness: %{enabled: true, required_backend: "vm"}
    }

    homes =
      for _ <- 1..55 do
        assert {:ok, home} = ModelServices.standalone_run_home(settings)
        assert Path.dirname(Path.dirname(home)) == ctx.sandboxes
        assert Path.basename(home) == "codex-home"
        assert {:ok, %{mode: mode}} = File.stat(home)
        assert Bitwise.band(mode, 0o777) == 0o700
        home
      end

    assert length(Enum.uniq(homes)) == 55
    assert length(File.ls!(ctx.sandboxes)) == 110
    assert Enum.all?(homes, &File.dir?/1)
    for {path, bytes} <- originals, do: assert(File.read!(path) == bytes)
  end

  # These deletion assertions require inspectable same-UID /proc descriptors. Run the gate
  # in a clean PID namespace; retaining everything must not masquerade as pruning coverage.
  test "legacy allocation still removes only the six oldest of fifty-five closed runs", ctx do
    runs =
      for number <- 1..55 do
        run = run!(ctx.sandboxes, "closed-#{number}")
        File.touch!(run, @old_time + number)
        run
      end

    assert {:ok, home} = ModelServices.standalone_run_home(%{state_dir: ctx.state})
    assert File.dir?(home)
    assert length(File.ls!(ctx.sandboxes)) == 50
    for run <- Enum.take(runs, 6), do: refute(File.exists?(run))
    for run <- Enum.drop(runs, 6), do: assert(File.dir?(run))
  end

  test "allocation reports a blocked run root without overwriting it", ctx do
    assert {:ok, nil} = ModelServices.standalone_run_home(nil)
    File.rmdir!(ctx.sandboxes)
    File.write!(ctx.sandboxes, "existing file")

    assert {:error, {:standalone_run_home_failed, :enotdir}} =
             ModelServices.standalone_run_home(%{state_dir: ctx.state})

    assert File.read!(ctx.sandboxes) == "existing file"
  end

  test "lost current directory pauses retention with a warning and preserves every transcript", ctx do
    originals = closed_transcripts!(ctx.sandboxes)

    previous_cwd = File.cwd!()
    workflow_store = Process.whereis(WorkflowStore)
    assert is_pid(workflow_store)
    assert Path.type(Workflow.workflow_file_path()) == :absolute
    obsolete_cwd = Path.join(ctx.root, "obsolete-cwd")
    File.mkdir_p!(obsolete_cwd)

    log =
      capture_log(fn ->
        :ok = :sys.suspend(Orchestrator)

        try do
          File.cd!(obsolete_cwd)
          File.rmdir!(obsolete_cwd)
          assert {:error, :enoent} = File.cwd()
          assert :ok = WorkflowStore.force_reload()
          assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
        after
          File.cd!(previous_cwd)
          :ok = :sys.resume(Orchestrator)
        end
      end)

    assert File.cwd!() == previous_cwd
    assert Process.whereis(WorkflowStore) == workflow_store
    assert :ok = WorkflowStore.force_reload()
    assert %Orchestrator.State{} = :sys.get_state(Orchestrator)
    assert log =~ "Run retention paused: filesystem evidence unavailable (File.Error)"
    for {path, bytes} <- originals, do: assert(File.read!(path) == bytes)

    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.ls!(ctx.sandboxes) == []
  end

  test "unreadable run roots and receipt directories preserve history without aborting pruning", ctx do
    retained = run!(ctx.sandboxes, "unreadable")
    File.write!(Path.join(retained, "history.jsonl"), "preserved")
    File.chmod!(ctx.sandboxes, 0o000)

    try do
      assert {:error, :eacces} = File.ls(ctx.sandboxes)
      assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    after
      File.chmod!(ctx.sandboxes, 0o700)
    end

    assert File.read!(Path.join(retained, "history.jsonl")) == "preserved"
    ordinary = run!(ctx.sandboxes, "closed-control")
    File.touch!(ordinary, @old_time)
    preserve_env!("SYMPHONY_STATE_DIR", ctx.state)
    File.chmod!(ctx.state, 0o000)
    File.chmod!(retained, 0o000)

    try do
      assert {:error, :eacces} = File.ls(ctx.state)
      assert {:error, :eacces} = File.ls(retained)
      assert :ok = ModelServices.prune_runs(ctx.sandboxes, 1)
      assert File.dir?(ordinary)
    after
      File.chmod!(ctx.state, 0o700)
      File.chmod!(retained, 0o700)
    end

    assert File.read!(Path.join(retained, "history.jsonl")) == "preserved"
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 1)
    refute File.exists?(ordinary)
    assert File.read!(Path.join(retained, "history.jsonl")) == "preserved"
  end

  test "an unreadable receipt preserves every run until receipt access is restored", ctx do
    workspace = Path.join(ctx.root, "receipt-workspace")
    File.mkdir_p!(workspace)
    receipt = Path.join(ctx.state, "issue-1.json")
    File.write!(receipt, Jason.encode!(%{"workspace" => workspace}))
    originals = closed_transcripts!(ctx.sandboxes)
    File.chmod!(receipt, 0o000)

    log =
      capture_log(fn ->
        try do
          assert {:error, :eacces} = File.read(receipt)
          assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
        after
          File.chmod!(receipt, 0o600)
        end
      end)

    assert log =~ "Run retention paused: filesystem evidence unavailable (File.Error)"
    for {path, bytes} <- originals, do: assert(File.read!(path) == bytes)
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.ls!(ctx.sandboxes) == []
  end

  test "an unreadable recovery journal preserves every run until journal access is restored", ctx do
    workspace = Path.join(ctx.root, "journal-workspace")
    journal = Path.join([workspace, ".symphony-import", "journal.json"])
    File.mkdir_p!(Path.dirname(journal))
    File.write!(journal, Jason.encode!(%{"export" => Path.join(ctx.root, "unrelated-export")}))
    preserve_env!("WORKSPACE", workspace)
    originals = closed_transcripts!(ctx.sandboxes)
    File.chmod!(journal, 0o000)

    log =
      capture_log(fn ->
        try do
          assert {:error, :eacces} = File.read(journal)
          assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
        after
          File.chmod!(journal, 0o600)
        end
      end)

    assert log =~ "Run retention paused: filesystem evidence unavailable (File.Error)"
    for {path, bytes} <- originals, do: assert(File.read!(path) == bytes)
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.ls!(ctx.sandboxes) == []
  end

  test "an untraversable import directory in a receipt workspace pauses pruning until its journal is discoverable", ctx do
    workspace = Path.join(ctx.root, "receipt-workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(ctx.state, "issue-1.json"), Jason.encode!(%{"workspace" => workspace}))

    assert_untraversable_recovery_preserves_all!(ctx, workspace, Path.join(workspace, ".symphony-import"))
  end

  test "an untraversable nested workspace pauses pruning until recursive journal discovery succeeds", ctx do
    workspace_root = Path.join(ctx.root, "detached-workspaces")
    blocked = Path.join(workspace_root, "nested")
    workspace = Path.join(blocked, "project")
    preserve_env!("WORKSPACE", workspace_root)

    assert_untraversable_recovery_preserves_all!(ctx, workspace, blocked)
  end

  test "pruning distinguishes completed exports from active, failed and unreadable results", ctx do
    for {name, contents} <- [
          {"completed", ~s({"cleanup_complete":true,"export_complete":true})},
          {"failed-export", ~s({"cleanup_complete":true,"export_complete":false})},
          {"unfinished", "{}"},
          {"malformed", "{"},
          {"non-object", "[]"},
          {"missing", nil},
          {"unreadable", :directory}
        ] do
      sandbox = Path.join(run!(ctx.sandboxes, name), "sandbox")
      File.mkdir_p!(sandbox)
      result = Path.join(sandbox, "result.json")

      case contents do
        nil -> :ok
        :directory -> File.mkdir_p!(result)
        bytes -> File.write!(result, bytes)
      end
    end

    ordinary = run!(ctx.sandboxes, "ordinary")
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    refute File.exists?(ordinary)
    refute File.exists?(Path.join(ctx.sandboxes, "run-completed"))

    for name <- ~w(failed-export unfinished malformed non-object missing unreadable) do
      assert File.dir?(Path.join(ctx.sandboxes, "run-#{name}"))
    end
  end

  test "an open transcript protects its run until the descriptor closes, including an unlinked file", ctx do
    for unlink? <- [false, true] do
      run = run!(ctx.sandboxes, "open-#{unlink?}")
      path = Path.join(run, "session.jsonl")
      file = File.open!(path, [:write])

      try do
        IO.binwrite(file, "first\n")
        if unlink?, do: File.rm!(path)
        ordinary = run!(ctx.sandboxes, "closed-control")
        assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
        refute File.exists?(ordinary)
        assert File.dir?(run)
        assert :ok = IO.binwrite(file, "second\n")
        unless unlink?, do: assert(File.read!(path) == "first\nsecond\n")
      after
        File.close(file)
      end

      assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
      refute File.exists?(run)
    end
  end

  test "a legacy recovery pin that cannot be written is kept beside the runs and survives a configuration switch", ctx do
    {workspace, journal, run, export} = legacy_journal!(ctx)
    # A read-only run directory refuses the in-run pin.
    File.chmod!(run, 0o555)
    on_exit(fn -> File.chmod(run, 0o755) end)

    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    refute File.exists?(Path.join(run, ".recovery-pin"))
    assert File.read!(ModelServices.detached_pin(ctx.sandboxes, run)) == "journal"

    # The workspace no longer reaches the journal, so discovery cannot protect the run any more.
    # An unprotected closed run proves pruning still works in this configuration.
    File.rm!(journal)
    System.delete_env("WORKSPACE")
    ordinary = run!(ctx.sandboxes, "ordinary")
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    refute File.exists?(ordinary)
    assert File.dir?(export)
    assert File.dir?(workspace)
  end

  test "a legacy recovery pin that cannot be written anywhere is reported while other runs are still pruned", ctx do
    {_workspace, _journal, run, export} = legacy_journal!(ctx)
    ordinary = run!(ctx.sandboxes, "ordinary")
    File.write!(Path.join(ordinary, "session.jsonl"), "closed")
    File.chmod!(run, 0o555)
    on_exit(fn -> File.chmod(run, 0o755) end)
    # A directory in the pin's place makes the beside-the-runs write fail too.
    File.mkdir_p!(ModelServices.detached_pin(ctx.sandboxes, run))

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0) end)
    assert log =~ "Recovery pin could not be written for run-recovery"
    assert File.dir?(export)
    refute File.exists?(ordinary)
  end

  test "detached recovery journals are pinned while malformed journals do not protect closed runs", ctx do
    workspace = Path.join(ctx.root, "detached-workspace")
    journal = Path.join([workspace, ".symphony-import", "journal.json"])
    File.mkdir_p!(Path.dirname(journal))
    preserve_env!("WORKSPACE", workspace)
    preserve_env!("SYMPHONY_WORKSPACE", "")
    run = run!(ctx.sandboxes, "recovery")
    ordinary = run!(ctx.sandboxes, "ordinary")
    File.write!(journal, Jason.encode!(%{"export" => Path.join(run, "sandbox/export")}))

    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.read!(Path.join(run, ".recovery-pin")) == "journal"
    refute File.exists?(ordinary)

    File.rm!(journal)
    System.delete_env("WORKSPACE")
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.dir?(run)

    System.put_env("WORKSPACE", workspace)
    File.rm!(Path.join(run, ".recovery-pin"))

    for invalid <- ["{", "{}", ~s({"export":3})] do
      File.write!(journal, invalid)
      closed = run!(ctx.sandboxes, "invalid-journal")
      assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
      refute File.exists?(closed)
    end
  end

  test "retention uses recent descendant writes, caps traversal and tolerates dangling links", ctx do
    recent = run!(ctx.sandboxes, "recent")
    transcript = Path.join([recent, "codex-home", "sessions", "active.jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "recent transcript")
    stamp_tree!(recent, @old_time)
    File.touch!(transcript, @old_time + 100)

    capped = run!(ctx.sandboxes, "deep")
    deep_file = Path.join([capped | List.duplicate("nested", 7)] ++ ["session.jsonl"])
    File.mkdir_p!(Path.dirname(deep_file))
    File.write!(deep_file, "beyond traversal limit")
    stamp_tree!(capped, @old_time)
    File.touch!(deep_file, @old_time + 200)
    File.ln_s!(Path.join(ctx.root, "missing"), Path.join(capped, "dangling"))
    File.touch!(capped, @old_time)
    unrelated = Path.join(ctx.sandboxes, "operator-notes")
    File.write!(unrelated, "keep")

    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 1)
    assert File.read!(transcript) == "recent transcript"
    refute File.exists?(capped)
    assert File.read!(unrelated) == "keep"
  end

  # A journal written before run-directory pins existed: only the configuration finds it.
  defp legacy_journal!(ctx) do
    workspace = Path.join(ctx.root, "detached-workspace")
    journal = Path.join([workspace, ".symphony-import", "journal.json"])
    File.mkdir_p!(Path.dirname(journal))
    preserve_env!("WORKSPACE", workspace)
    preserve_env!("SYMPHONY_WORKSPACE", "")
    run = run!(ctx.sandboxes, "recovery")
    export = Path.join(run, "sandbox/export")
    File.mkdir_p!(export)
    # A completed export: only the journal reference or a pin still protects this run.
    File.write!(Path.join([run, "sandbox", "result.json"]), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true}))
    File.write!(journal, Jason.encode!(%{"export" => export}))
    {workspace, journal, run, export}
  end

  defp run!(sandboxes, name) do
    path = Path.join(sandboxes, "run-#{name}")
    File.mkdir_p!(path)
    path
  end

  defp closed_transcripts!(sandboxes) do
    for number <- 1..2 do
      run = run!(sandboxes, "closed-#{number}")
      transcript = Path.join(run, "session.jsonl")
      bytes = "original session #{number}\n"
      File.write!(transcript, bytes)
      {transcript, bytes}
    end
  end

  defp assert_untraversable_recovery_preserves_all!(ctx, workspace, blocked) do
    originals = closed_transcripts!(ctx.sandboxes)
    [{transcript, bytes}, {ordinary, _}] = originals
    recovered_run = Path.dirname(transcript)
    sandbox = Path.join(recovered_run, "sandbox")
    export = Path.join(sandbox, "export")
    File.mkdir_p!(export)
    File.write!(Path.join(export, "candidate.txt"), "recoverable candidate")
    File.write!(Path.join(sandbox, "result.json"), Jason.encode!(%{"cleanup_complete" => true, "export_complete" => true}))
    journal = Path.join([workspace, ".symphony-import", "journal.json"])
    File.mkdir_p!(Path.dirname(journal))
    File.write!(journal, Jason.encode!(%{"schema" => 2, "export" => export}))
    File.chmod!(blocked, 0o000)

    log =
      capture_log(fn ->
        try do
          assert {:error, :eacces} = File.ls(blocked)
          assert {:error, :eacces} = File.read(journal)
          assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
        after
          File.chmod!(blocked, 0o700)
        end
      end)

    for {path, original} <- originals, do: assert(File.read!(path) == original)
    assert log =~ "Run retention paused: filesystem evidence unavailable (File.Error)"
    assert File.read!(Path.join(export, "candidate.txt")) == "recoverable candidate"

    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    assert File.read!(Path.join(recovered_run, ".recovery-pin")) == "journal"
    assert File.read!(transcript) == bytes
    assert File.read!(Path.join(export, "candidate.txt")) == "recoverable candidate"
    refute File.exists?(Path.dirname(ordinary))
    assert File.ls!(ctx.sandboxes) == [Path.basename(recovered_run)]

    later = run!(ctx.sandboxes, "later-closed-session")
    assert :ok = ModelServices.prune_runs(ctx.sandboxes, 0)
    refute File.exists?(later)
    assert File.read!(Path.join(recovered_run, ".recovery-pin")) == "journal"
  end

  defp stamp_tree!(path, time) do
    if File.dir?(path) do
      for name <- File.ls!(path), do: stamp_tree!(Path.join(path, name), time)
    end

    File.touch!(path, time)
  end

  defp preserve_env!(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end
