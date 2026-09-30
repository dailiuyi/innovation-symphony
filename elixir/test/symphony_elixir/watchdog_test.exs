defmodule SymphonyElixir.WatchdogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Watchdog

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-watchdog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    state_dir = Path.join(root, "watchdog-state")
    workflow = Path.join(root, "WORKFLOW.md")
    pointer = Path.join(root, "current.json")
    credential = Path.join(root, "github-token")
    File.write!(workflow, "fixed workflow")
    File.write!(credential, "test-token\n")
    File.chmod!(credential, 0o600)

    config = %{
      "controller" => Path.join(root, "controller"),
      "pointer_file" => pointer,
      "state_dir" => state_dir,
      "status_file" => Path.join(state_dir, "status.json"),
      "maintenance_file" => Path.join(state_dir, "maintenance.lock"),
      "workflow" => workflow,
      "credential_file" => credential,
      "logs_root" => Path.join(root, "logs"),
      "interval_ms" => 50,
      "backoff_ms" => 10_000,
      "max_attempts" => 2,
      "stable_ms" => 10_000,
      "port" => nil
    }

    install = install!(root, "v1", "while :; do sleep 1; done")
    pointer!(config, "v1", install)

    on_exit(fn ->
      case File.read(Path.join(state_dir, "status.json")) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, %{"process" => %{"pid" => pid}}} -> kill_group(pid, workflow)
            _ -> :ok
          end

        _ ->
          :ok
      end

      File.rm_rf(root)
    end)

    {:ok, root: root, config: config, install: install}
  end

  test "rejects malformed config and pointer without an attempt", ctx do
    assert {:error, _} = Watchdog.load_config(Path.join(ctx.root, "missing.json"))
    config_path = Path.join(ctx.root, "config.json")
    File.write!(config_path, ~s({"interval_ms":"bad"}))
    assert {:error, _} = Watchdog.load_config(config_path)

    for changes <- [
          %{"max_attempts" => 0},
          %{"port" => 65_536},
          %{"workflow" => "relative.md"},
          %{"credential_file" => "/tmp/invalid" <> <<0>>}
        ] do
      File.write!(config_path, Jason.encode!(Map.merge(ctx.config, changes)))
      assert {:error, _} = Watchdog.load_config(config_path)
    end

    File.write!(config_path, Jason.encode!(ctx.config))
    assert {:ok, _} = Watchdog.load_config(config_path)
    File.write!(config_path, Jason.encode!(Map.put(ctx.config, "port", 0)))
    assert {:ok, _} = Watchdog.load_config(config_path)

    File.rm!(ctx.config["pointer_file"])
    assert {:ok, state} = Watchdog.step(ctx.config, "check")
    assert state["phase"] == "blocked"
    assert state["versions"] == %{}
    assert state["last_action"]["reason"] =~ "pointer"

    for malformed <- [
          "not json",
          ~s({"version":"../v1","install":"/missing"}),
          ~s({"version":"v1","install":"/missing/v1"})
        ] do
      File.write!(ctx.config["pointer_file"], malformed)
      assert {:ok, blocked} = Watchdog.step(ctx.config, "check")
      assert blocked["phase"] == "blocked"
      assert blocked["versions"] == %{}
    end

    alias_path = Path.join(ctx.root, "v1-alias")
    File.ln_s!(ctx.install, alias_path)
    pointer!(ctx.config, "v1-alias", alias_path)
    assert {:ok, blocked_alias} = Watchdog.step(ctx.config, "check")
    assert blocked_alias["versions"] == %{}
    assert length(history(ctx.config)) == 5

    assert {:ok, unrecoverable} = Watchdog.step(ctx.config, "recover")
    assert unrecoverable["phase"] == "blocked"
    assert unrecoverable["versions"] == %{}
  end

  test "missing and unsafe credential block without consuming budget or exposing a value", ctx do
    File.rm!(ctx.config["credential_file"])
    assert {:ok, missing} = Watchdog.step(ctx.config, "start")
    assert missing["versions"] == %{}
    assert missing["last_action"]["reason"] =~ "credential"

    File.write!(ctx.config["credential_file"], "secret-marker")
    File.chmod!(ctx.config["credential_file"], 0o644)
    assert {:ok, unsafe} = Watchdog.step(ctx.config, "check")
    assert unsafe["versions"] == %{}
    File.chmod!(ctx.config["credential_file"], 0o000)
    assert {:ok, unreadable} = Watchdog.step(ctx.config, "check")
    assert unreadable["versions"] == %{}
    refute File.read!(Path.join(ctx.config["state_dir"], "status.json")) =~ "secret-marker"
    refute File.read!(Path.join(ctx.config["state_dir"], "history.jsonl")) =~ "secret-marker"
  end

  test "launch, identity, pointer change, pause and stable round reset", ctx do
    injected = Path.join(ctx.root, "injected-token")

    install!(
      ctx.root,
      "v1",
      "printf '%s' \"$GITHUB_TOKEN\" > '#{injected}'\nwhile :; do sleep 1; done"
    )

    assert {:ok, started} = Watchdog.step(ctx.config, "start")
    assert started["phase"] == "running"
    assert started["versions"]["v1"]["attempts"] == 1
    pid = started["process"]["pid"]
    assert File.exists?("/proc/#{pid}")
    wait_file(injected)
    assert File.read!(injected) == "test-token"
    refute File.read!(ctx.config["status_file"]) =~ "test-token"
    refute File.read!(Path.join(ctx.config["state_dir"], "history.jsonl")) =~ "test-token"

    assert {:ok, observed} = Watchdog.step(ctx.config, "check")
    assert observed["process"]["pid"] == pid

    change_state(ctx.config, fn state ->
      put_in(state, ["process", "cmdline"], ["launcher"] ++ state["process"]["cmdline"])
    end)

    assert {:ok, after_exec} = Watchdog.step(ctx.config, "check")
    assert after_exec["phase"] == "running"
    assert after_exec["process"]["pid"] == pid
    refute hd(after_exec["process"]["cmdline"]) == "launcher"
    assert {:ok, changed_port} = Watchdog.step(Map.put(ctx.config, "port", 1), "check")
    assert changed_port["phase"] == "blocked"
    assert changed_port["process"]["pid"] == pid

    File.write!(ctx.config["pointer_file"], "malformed")
    assert {:ok, pointer_error_while_running} = Watchdog.step(ctx.config, "check")
    assert pointer_error_while_running["process"]["pid"] == pid

    install2 = install!(ctx.root, "v2", "while :; do sleep 1; done")
    pointer!(ctx.config, "v2", install2)
    assert {:ok, old_running} = Watchdog.step(ctx.config, "check")
    assert old_running["pointer"]["version"] == "v2"
    assert old_running["observed"]["version"] == "v1"
    assert old_running["process"]["pid"] == pid

    assert {:ok, paused} = Watchdog.step(ctx.config, "pause")
    assert paused["paused"]
    assert File.regular?(ctx.config["maintenance_file"])
    assert File.exists?("/proc/#{pid}")
    kill_group(pid, ctx.config["workflow"])
    wait_absent(pid)
    assert {:ok, blocked} = Watchdog.step(ctx.config, "check")
    assert blocked["phase"] == "paused"
    assert blocked["process"] == nil
    assert Enum.any?(history(ctx.config), &(&1["action"] == "exit"))

    assert {:ok, resumed} = Watchdog.step(ctx.config, "resume")
    refute resumed["paused"]
    refute File.exists?(ctx.config["maintenance_file"])
    assert {:ok, newer} = Watchdog.step(ctx.config, "check")
    assert newer["observed"]["version"] == "v2"
    assert newer["versions"]["v1"]["attempts"] == 1

    change_state(ctx.config, fn state -> put_in(state, ["process", "seen_at"], 0) end)
    assert {:ok, stable} = Watchdog.step(ctx.config, "check")
    assert stable["versions"]["v2"]["attempts"] == 0
    assert stable["history_count"] > 1
  end

  test "configured status port is passed to the fixed runner and checked in its identity", ctx do
    arguments = Path.join(ctx.root, "runner-arguments")
    install!(ctx.root, "v1", "printf '%s\\n' \"$@\" > '#{arguments}'\nwhile :; do sleep 1; done")
    config = Map.put(ctx.config, "port", 1)

    assert {:ok, started} = Watchdog.step(config, "start")
    assert started["phase"] == "running"
    assert ["--port", "1"] in Enum.chunk_every(started["process"]["cmdline"], 2, 1, :discard)
    wait_file(arguments)
    assert File.read!(arguments) =~ "--port\n1\n"

    # The test runner deliberately has no listener; an unresponsive port is not an exit.
    assert {:ok, present} = Watchdog.step(config, "check")
    assert present["process"]["pid"] == started["process"]["pid"]
    assert present["versions"]["v1"]["attempts"] == 1
  end

  test "workflow status port is used for launch and unknown occupancy when no override is set", ctx do
    File.write!(ctx.config["workflow"], "---\nserver:\n  port: 43210\n---\n")
    fake_proc = Path.join(ctx.root, "port-proc")
    File.mkdir_p!(Path.join(fake_proc, "net"))
    File.write!(Path.join(fake_proc, "net/tcp"), "0: 0100007F:A8CA 00000000:0000 0A 0 0\n")
    File.write!(Path.join(fake_proc, "net/tcp6"), "")

    assert {:ok, blocked} = Watchdog.step(Map.put(ctx.config, :proc_root, fake_proc), "check")
    assert blocked["phase"] == "blocked"
    assert blocked["last_action"]["reason"] =~ "port occupied"
    assert blocked["versions"] == %{}

    File.write!(ctx.config["workflow"], "---\nserver:\n  port: 1\n---\n")
    assert {:ok, started} = Watchdog.step(ctx.config, "start")
    assert ["--port", "1"] in Enum.chunk_every(started["process"]["cmdline"], 2, 1, :discard)
    assert {:ok, alive} = Watchdog.step(ctx.config, "check")
    assert alive["process"]["pid"] == started["process"]["pid"]

    File.write!(ctx.config["workflow"], "---\nserver:\n  port: 70000\n---\n")
    assert {:ok, invalid} = Watchdog.step(ctx.config, "check")
    assert invalid["phase"] == "blocked"
    assert invalid["versions"]["v1"]["attempts"] == 1
  end

  test "the last permitted launch cannot earn a fresh round by staying alive", ctx do
    config = Map.put(ctx.config, "max_attempts", 1)
    assert {:ok, started} = Watchdog.step(config, "start")
    assert started["versions"]["v1"]["attempts"] == 1

    change_state(config, fn state -> put_in(state, ["process", "seen_at"], 0) end)
    assert {:ok, stable} = Watchdog.step(config, "check")
    assert stable["versions"]["v1"]["attempts"] == 1
    refute stable["last_action"]["reason"] =~ "round reset"

    pid = stable["process"]["pid"]
    kill_group(pid, config["workflow"])
    wait_absent(pid)
    assert {:ok, exhausted} = Watchdog.step(config, "check")
    assert exhausted["phase"] == "awaiting_human"
    assert exhausted["versions"]["v1"]["attempts"] == 1

    assert {:ok, still_exhausted} = Watchdog.step(config, "check")
    assert still_exhausted["phase"] == "awaiting_human"
    assert {:ok, recovered} = Watchdog.step(config, "recover")
    assert recovered["versions"]["v1"]["attempts"] == 0
    assert_audit_complete(config)
  end

  test "identity conflict and missing record fail closed", ctx do
    config = controlled_proc_config(ctx)
    assert {:ok, started} = Watchdog.step(config, "start")
    assert started["phase"] == "running", inspect(started["last_action"])
    assert is_map(started["process"]), inspect(started)
    assert Jason.decode!(File.read!(config["status_file"]))["process"] == started["process"]
    pid = started["process"]["pid"]
    change_state(config, fn state -> put_in(state, ["process", "start_ticks"], "reused") end)
    assert {:ok, conflict} = Watchdog.step(config, "check")
    assert conflict["phase"] == "blocked"
    assert conflict["last_action"]["reason"] =~ "identity conflict"
    assert conflict["process"]["pid"] == pid
    assert conflict["process"]["start_ticks"] == "reused"
    assert conflict["observed"]["pid"] == pid
    assert conflict["observed"]["start_ticks"] == started["process"]["start_ticks"]
    assert List.last(history(config))["process"]["start_ticks"] == "reused"

    assert List.last(history(config))["observed"]["start_ticks"] ==
             started["process"]["start_ticks"]

    change_state(config, fn state ->
      state
      |> put_in(["process", "start_ticks"], started["process"]["start_ticks"])
      |> put_in(["process", "cmdline"], Enum.reverse(started["process"]["cmdline"]))
    end)

    assert {:ok, command_conflict} = Watchdog.step(config, "check")
    assert command_conflict["phase"] == "blocked"
    assert command_conflict["process"]["pid"] == pid
    assert command_conflict["observed"]["cmdline"] == started["process"]["cmdline"]

    change_state(config, fn state -> Map.put(state, "process", nil) end)
    assert {:ok, unrecorded} = Watchdog.step(config, "check")
    assert unrecorded["phase"] == "blocked"
    assert unrecorded["last_action"]["reason"] =~ "unrecorded runner"
    assert File.exists?("/proc/#{pid}")
    kill_group(pid, ctx.config["workflow"])
  end

  test "a recorded PID reused by an unrelated process is not treated as this runner", ctx do
    config = controlled_proc_config(ctx)
    assert {:ok, started} = Watchdog.step(config, "start")
    assert started["phase"] == "running", inspect(started["last_action"])
    assert is_binary(started["process"]["start_ticks"])
    assert Jason.decode!(File.read!(config["status_file"]))["process"] == started["process"]
    kill_group(started["process"]["pid"], ctx.config["workflow"])
    wait_absent(started["process"]["pid"])
    {raw_pid, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    {unrelated_pid, ""} = raw_pid |> String.trim() |> Integer.parse()

    on_exit(fn ->
      case File.read("/proc/#{unrelated_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, "sleep"),
            do: System.cmd("kill", [Integer.to_string(unrelated_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end
    end)

    File.ln_s!("/proc/#{unrelated_pid}", Path.join(config[:proc_root], Integer.to_string(unrelated_pid)))
    change_state(config, fn state -> put_in(state, ["process", "pid"], unrelated_pid) end)

    assert {:ok, blocked} = Watchdog.step(config, "check")
    assert blocked["phase"] == "blocked"
    assert blocked["versions"]["v1"]["attempts"] == 1
    assert blocked["process"]["pid"] == unrelated_pid
    assert blocked["observed"]["pid"] == unrelated_pid
    assert blocked["observed"]["cmdline"] != started["process"]["cmdline"]
    assert File.exists?("/proc/#{unrelated_pid}")
  end

  test "failed starts back off, exhaust per-version budget and require explicit recovery", ctx do
    proc_root = Path.join(ctx.root, "empty-proc")
    File.mkdir_p!(proc_root)

    config =
      ctx.config
      |> Map.put(:proc_root, proc_root)
      |> Map.put(:spawn_command, fn _, _, _ -> {"failed", 1} end)

    assert {:ok, first} = Watchdog.step(config, "check")
    assert first["versions"]["v1"]["attempts"] == 1
    assert first["phase"] == "backoff"
    assert first["last_action"]["reason"] == "launcher failed"
    assert first["observed"] == nil
    assert {:ok, waiting} = Watchdog.step(config, "check")
    assert waiting["phase"] == "backoff"
    assert waiting["versions"]["v1"]["attempts"] == 1

    change_state(config, fn state -> put_in(state, ["versions", "v1", "next_at"], 0) end)
    assert {:ok, second} = Watchdog.step(config, "check")
    assert second["versions"]["v1"]["attempts"] == 2
    assert second["phase"] == "awaiting_human"
    assert second["versions"]["v1"]["awaiting_human"]

    assert Enum.take(Enum.map(history(config), & &1["action"]), -2) == [
             "launch_failed",
             "abandon"
           ]

    assert {:ok, still_exhausted} = Watchdog.step(config, "check")
    assert still_exhausted["versions"]["v1"]["attempts"] == 2
    assert {:ok, _} = Watchdog.step(config, "pause")
    assert {:ok, resumed} = Watchdog.step(config, "resume")
    assert resumed["versions"]["v1"]["awaiting_human"]
    assert {:ok, after_resume} = Watchdog.step(config, "check")
    assert after_resume["phase"] == "awaiting_human"

    install2 = install!(ctx.root, "v2", "exit 0")
    pointer!(config, "v2", install2)
    assert {:ok, other} = Watchdog.step(config, "check")
    assert other["versions"]["v2"]["attempts"] == 1
    assert other["phase"] == "backoff"
    assert other["last_action"]["reason"] == "launcher failed"
    pointer!(config, "v1", ctx.install)

    missing_proc = Map.put(config, :proc_root, Path.join(ctx.root, "missing-proc"))
    assert {:ok, inaccessible} = Watchdog.step(missing_proc, "check")
    assert inaccessible["phase"] == "blocked"
    assert inaccessible["last_action"]["reason"] == "cannot scan process table"
    assert inaccessible["observed"] == nil
    assert inaccessible["versions"]["v1"]["awaiting_human"]
    assert List.last(history(config))["reason"] == "cannot scan process table"

    suspect = Path.join(proc_root, "123456")
    File.mkdir_p!(suspect)
    File.write!(Path.join(suspect, "cmdline"), "symphony\0#{config["workflow"]}\0")
    assert {:ok, suspicious} = Watchdog.step(config, "check")
    assert suspicious["phase"] == "blocked"
    assert suspicious["last_action"]["reason"] =~ "unrecorded runner-like process"
    assert suspicious["observed"]["pid"] == 123_456
    assert List.last(history(config))["observed"]["pid"] == 123_456
    assert suspicious["versions"]["v1"]["attempts"] == 2
    File.rm_rf!(suspect)

    assert {:ok, old} = Watchdog.step(config, "check")
    assert old["phase"] == "awaiting_human"
    assert old["last_action"]["reason"] == "version budget exhausted"
    assert old["observed"] == nil
    assert old["versions"]["v1"]["attempts"] == 2
    assert old["versions"]["v2"]["attempts"] == 1
    assert Enum.count(history(config), &(&1["action"] == "attempt")) == 3
    assert List.last(history(config))["action"] == "abandon"

    previous = old["history_count"]
    assert {:ok, recovered} = Watchdog.step(config, "recover")
    assert recovered["versions"]["v1"]["attempts"] == 0
    assert recovered["versions"]["v2"]["attempts"] == 1
    assert recovered["history_count"] == previous + 1
    assert List.last(history(config))["action"] == "recover"
    assert {:ok, retried} = Watchdog.step(config, "check")
    assert retried["versions"]["v1"]["attempts"] == 1
    assert retried["last_action"]["reason"] == "launcher failed"
    assert retried["observed"] == nil
    assert retried["history_count"] == length(history(config))
    assert List.last(history(config))["reason"] == "launcher failed"
  end

  test "a real runner that exits immediately consumes one attempt and backs off", ctx do
    install!(ctx.root, "v1", "exit 2")
    exited = check_after_quick_exit(ctx.config)
    assert exited["phase"] == "backoff"
    assert exited["versions"]["v1"]["attempts"] == 1
    assert exited["process"] == nil
    assert exited["observed"] == nil
    assert Enum.count(history(ctx.config), &(&1["action"] == "attempt")) == 1
  end

  test "normal and abnormal exits use the same backoff and relaunch path", ctx do
    config = Map.put(ctx.config, "backoff_ms", 10_000)
    stop_file = Path.join(ctx.root, "stop-normally")
    install!(ctx.root, "v1", "while [ ! -e '#{stop_file}' ]; do sleep 0.02; done")
    assert {:ok, first} = Watchdog.step(config, "check")
    first_pid = first["process"]["pid"]
    File.write!(stop_file, "stop")
    wait_absent(first_pid)
    File.rm!(stop_file)

    assert {:ok, after_normal_exit} = Watchdog.step(config, "check")
    assert after_normal_exit["process"] == nil
    assert after_normal_exit["phase"] == "backoff"
    change_state(config, fn state -> put_in(state, ["versions", "v1", "next_at"], 0) end)
    assert {:ok, second} = Watchdog.step(config, "check")
    assert second["process"]["pid"] != first_pid
    assert second["versions"]["v1"]["attempts"] == 2

    second_pid = second["process"]["pid"]
    kill_group(second_pid, config["workflow"], "-KILL")
    wait_absent(second_pid)
    assert {:ok, after_abnormal_exit} = Watchdog.step(config, "check")
    assert after_abnormal_exit["phase"] == "awaiting_human"
    assert after_abnormal_exit["versions"]["v1"]["awaiting_human"]
    assert Enum.count(history(config), &(&1["action"] == "exit")) == 2
    assert Enum.map(Enum.filter(history(config), &(&1["action"] == "exit")), & &1["observed"]["pid"]) == [first_pid, second_pid]
    assert_audit_complete(config)
  end

  test "pause persists through state reload and recovery does not clear it", ctx do
    proc_root = Path.join(ctx.root, "empty-proc")
    File.mkdir_p!(proc_root)
    config = Map.put(ctx.config, :proc_root, proc_root)
    File.mkdir_p!(ctx.config["state_dir"])
    File.write!(ctx.config["maintenance_file"], "external maintenance")
    assert {:ok, externally_paused} = Watchdog.step(config, "check")
    assert externally_paused["phase"] == "paused", externally_paused["last_action"]["reason"]
    assert externally_paused["versions"] == %{}

    assert {:ok, paused} = Watchdog.step(config, "pause")
    assert paused["paused"]
    assert {:ok, next} = Watchdog.step(config, "check")
    assert next["phase"] == "paused", next["last_action"]["reason"]
    assert next["versions"] == %{}
    assert {:ok, recovered} = Watchdog.step(config, "recover")
    assert recovered["paused"]
    assert {:ok, resumed} = Watchdog.step(config, "resume")
    refute resumed["paused"]
    assert {:ok, started} = Watchdog.step(ctx.config, "check")
    assert started["phase"] == "running"

    assert {:ok, status} = Watchdog.step(ctx.config, "status")
    assert status["history_count"] == started["history_count"]
    actions = Enum.map(history(ctx.config), & &1["action"])
    assert Enum.all?(~w(blocked pause resume recover launch), &(&1 in actions))
    assert_audit_complete(ctx.config)
  end

  test "corrupt state is never treated as a fresh budget", ctx do
    assert {:ok, _} = Watchdog.step(ctx.config, "pause")

    File.write!(
      Path.join(ctx.config["state_dir"], "status.json"),
      ~s({"paused":false,"versions":{"v1":{"attempts":"bad"}}})
    )

    assert {:error, reason} = Watchdog.step(ctx.config, "check")
    assert reason =~ "refusing to reset budget"

    File.write!(ctx.config["status_file"], "not json")
    assert {:error, ^reason} = Watchdog.step(ctx.config, "check")
  end

  test "audit restores a launch recorded just before status replacement", ctx do
    counter = :atomics.new(1, [])

    crashing =
      Map.put(ctx.config, :after_audit, fn ->
        if :atomics.add_get(counter, 1, 1) == 2, do: raise("crash after audit")
        :ok
      end)

    assert_raise RuntimeError, "crash after audit", fn -> Watchdog.step(crashing, "start") end

    stale = ctx.config["status_file"] |> File.read!() |> Jason.decode!()
    assert stale["history_count"] == 1
    assert stale["versions"]["v1"]["attempts"] == 1
    assert length(history(ctx.config)) == 2

    assert {:ok, restored} = Watchdog.step(ctx.config, "status")
    assert restored["history_count"] == 2
    assert restored["process"]["pid"] > 0
    assert File.exists?("/proc/#{restored["process"]["pid"]}")
    assert {:ok, checked} = Watchdog.step(ctx.config, "check")
    assert checked["process"]["pid"] == restored["process"]["pid"]
    assert checked["versions"]["v1"]["attempts"] == 1
    assert_audit_complete(ctx.config)
  end

  test "missing status recovers from audit, while malformed audit blocks", ctx do
    assert {:ok, paused} = Watchdog.step(ctx.config, "pause")
    File.rm!(ctx.config["status_file"])
    assert {:ok, restored} = Watchdog.step(ctx.config, "status")
    assert restored["history_count"] == paused["history_count"]
    assert restored["paused"]

    audit = Path.join(ctx.config["state_dir"], "history.jsonl")
    File.write!(audit, "not json\n", [:append])
    assert {:error, reason} = Watchdog.step(ctx.config, "check")
    assert reason =~ "invalid watchdog audit"
    assert File.read!(ctx.config["status_file"]) |> Jason.decode!() |> Map.fetch!("paused")
  end

  test "locked CLI blockage is auditable and mismatched valid status blocks", ctx do
    assert {:ok, blocked} = Watchdog.record_block(ctx.config, "controller executable missing")
    assert Watchdog.valid_response?(blocked, ctx.config)
    refute Watchdog.valid_response?(%{}, ctx.config)
    assert blocked["history_count"] == 1
    assert List.last(history(ctx.config))["reason"] == "controller executable missing"

    File.write!(ctx.config["status_file"], Jason.encode!(%{blocked | "phase" => "running"}))
    assert {:error, reason} = Watchdog.step(ctx.config, "start")
    assert reason =~ "refusing to reset budget"
    assert length(history(ctx.config)) == 1
  end

  test "unreadable state and unverifiable maintenance lock fail closed", ctx do
    File.mkdir_p!(ctx.config["state_dir"])
    File.mkdir_p!(ctx.config["status_file"])
    assert {:error, "watchdog state unreadable"} = Watchdog.step(ctx.config, "check")

    File.rmdir!(ctx.config["status_file"])
    blocker = Path.join(ctx.root, "not-a-directory")
    File.write!(blocker, "block")
    config = Map.put(ctx.config, "maintenance_file", Path.join(blocker, "maintenance.lock"))
    assert {:error, "maintenance lock cannot be verified"} = Watchdog.step(config, "check")
  end

  test "maintenance and audit write errors do not report success", ctx do
    File.mkdir_p!(ctx.config["state_dir"])
    File.mkdir_p!(ctx.config["maintenance_file"])
    assert {:error, "cannot update maintenance lock"} = Watchdog.step(ctx.config, "pause")
    File.rmdir!(ctx.config["maintenance_file"])

    File.mkdir_p!(Path.join(ctx.config["state_dir"], "history.jsonl"))

    assert {:error, "watchdog audit unreadable; refusing to reset budget"} =
             Watchdog.step(ctx.config, "pause")
  end

  test "a stored budget survives a missing maintenance file and explicit resume", ctx do
    assert {:ok, started} = Watchdog.step(ctx.config, "check")
    assert started["versions"]["v1"]["attempts"] == 1
    assert {:ok, resumed} = Watchdog.step(ctx.config, "resume")
    assert resumed["versions"]["v1"]["attempts"] == 1
    assert {:error, "unknown watchdog operation"} = Watchdog.step(ctx.config, "invalid")
  end

  test "unverifiable process table and status port block without a launch", ctx do
    missing = Map.put(ctx.config, :proc_root, Path.join(ctx.root, "missing-proc"))
    assert {:ok, blocked} = Watchdog.step(missing, "check")
    assert blocked["last_action"]["reason"] == "cannot scan process table"
    assert blocked["versions"] == %{}

    fake_proc = Path.join(ctx.root, "fake-proc")
    File.mkdir_p!(Path.join(fake_proc, "123"))
    File.mkdir_p!(Path.join(fake_proc, "net"))
    File.mkdir_p!(Path.join(fake_proc, "123/cmdline"))
    config = Map.put(ctx.config, :proc_root, fake_proc)
    assert {:ok, unreadable} = Watchdog.step(config, "check")
    assert unreadable["last_action"]["reason"] == "process table identity inaccessible"
    assert unreadable["versions"] == %{}

    File.rmdir!(Path.join(fake_proc, "123/cmdline"))
    assert {:ok, port_blocked} = Watchdog.step(Map.put(config, "port", 43_210), "check")
    assert port_blocked["last_action"]["reason"] =~ "port occupied"
    assert port_blocked["versions"] == %{}
  end

  test "malformed proc identity is never accepted as a running service", ctx do
    assert {:ok, started} = Watchdog.step(ctx.config, "start")
    pid = started["process"]["pid"]
    fake_proc = Path.join(ctx.root, "fake-proc")
    proc_dir = Path.join(fake_proc, Integer.to_string(pid))
    File.mkdir_p!(proc_dir)
    File.mkdir_p!(Path.join(fake_proc, "sys/kernel/random"))
    File.write!(Path.join(fake_proc, "sys/kernel/random/boot_id"), "fake-boot")
    File.write!(Path.join(proc_dir, "cmdline"), Enum.join(started["process"]["cmdline"], <<0>>))
    config = Map.put(ctx.config, :proc_root, fake_proc)

    for malformed <- ["not a proc stat", "#{pid} (runner) S 0", proc_stat(pid, "Z")] do
      File.write!(Path.join(proc_dir, "stat"), malformed)
      assert {:ok, blocked} = Watchdog.step(config, "check")
      assert blocked["phase"] == "blocked"
      assert blocked["versions"]["v1"]["attempts"] == 1
      assert blocked["process"]["pid"] == pid
      assert blocked["observed"]["pid"] == pid

      if malformed != proc_stat(pid, "Z") do
        assert blocked["observed"]["verification"] == "unverifiable"
      end
    end

    File.write!(Path.join(proc_dir, "stat"), proc_stat(pid, "S"))
    assert {:ok, wrong_boot} = Watchdog.step(config, "check")
    assert wrong_boot["last_action"]["reason"] =~ "identity conflict"
  end

  test "launcher errors and malformed PIDs consume budget with redacted evidence", ctx do
    for {reply, reason} <- [
          {{"failed", 1}, "launcher failed"},
          {{"not-a-pid", 0}, "launcher returned no process id"},
          {{"99999999", 0}, "started process exited before identity recording"}
        ] do
      assert {:ok, _} = Watchdog.step(ctx.config, "recover")

      config =
        Map.put(ctx.config, :spawn_command, fn command, [_flag, _script], options ->
          assert command == "sh"
          assert {"GITHUB_TOKEN", "test-token"} in options[:env]
          reply
        end)

      assert {:ok, failed} = Watchdog.step(config, "check")
      assert failed["phase"] == "backoff"
      assert failed["last_action"]["reason"] == reason
      assert failed["versions"]["v1"]["attempts"] == 1
      refute File.read!(ctx.config["status_file"]) =~ "test-token"
    end
  end

  test "launcher execution exceptions retain failure evidence and exhaust the budget", ctx do
    empty_proc = Path.join(ctx.root, "empty-proc")
    File.mkdir_p!(empty_proc)

    config =
      ctx.config
      |> Map.put(:proc_root, empty_proc)
      |> Map.put(:spawn_command, fn _command, args, options ->
        System.cmd(Path.join(ctx.root, "missing-shell"), args, options)
      end)

    assert {:ok, first} = Watchdog.step(config, "check")
    assert first["phase"] == "backoff"
    assert first["last_action"]["reason"] == "launcher execution error"
    assert first["versions"]["v1"]["attempts"] == 1

    assert Enum.take(Enum.map(history(config), & &1["action"]), -2) == [
             "attempt",
             "launch_failed"
           ]

    change_state(config, fn state -> put_in(state, ["versions", "v1", "next_at"], 0) end)
    assert {:ok, exhausted} = Watchdog.step(config, "check")
    assert exhausted["phase"] == "awaiting_human"
    assert exhausted["versions"]["v1"]["attempts"] == 2

    assert Enum.take(Enum.map(history(config), & &1["action"]), -3) == [
             "attempt",
             "launch_failed",
             "abandon"
           ]

    assert {:ok, restarted} = Watchdog.step(config, "check")
    assert restarted["phase"] == "awaiting_human"
    assert restarted["versions"]["v1"]["attempts"] == 2
    assert Enum.count(history(config), &(&1["action"] == "attempt")) == 2
    refute File.read!(config["status_file"]) =~ "test-token"
    refute File.read!(Path.join(config["state_dir"], "history.jsonl")) =~ "test-token"
  end

  test "the transient setsid launcher is never recorded as the runner", ctx do
    pid = 778_899
    fake_proc = Path.join(ctx.root, "fake-proc")
    proc_dir = Path.join(fake_proc, Integer.to_string(pid))
    File.mkdir_p!(proc_dir)
    File.mkdir_p!(Path.join(fake_proc, "sys/kernel/random"))
    File.write!(Path.join(fake_proc, "sys/kernel/random/boot_id"), "fake-boot")
    File.write!(Path.join(proc_dir, "stat"), proc_stat(pid, "S"))
    command_file = Path.join(proc_dir, "cmdline")
    File.write!(command_file, "idle")

    config =
      ctx.config
      |> Map.put(:proc_root, fake_proc)
      |> Map.put(:spawn_command, fn _, _, _ ->
        command = [
          "setsid",
          Path.join(ctx.install, "bin/symphony"),
          "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
          "--logs-root",
          ctx.config["logs_root"],
          ctx.config["workflow"]
        ]

        File.write!(command_file, Enum.join(command, <<0>>))
        {Integer.to_string(pid), 0}
      end)

    assert {:ok, blocked} = Watchdog.step(config, "check")
    assert blocked["phase"] == "backoff"
    assert blocked["last_action"]["reason"] =~ "exited before identity recording"
    assert blocked["process"] == nil
  end

  test "unrelated listener blocks a launch without consuming budget", ctx do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, {_address, port}} = :inet.sockname(socket)
    proc_root = Path.join(ctx.root, "port-proc")
    File.mkdir_p!(Path.join(proc_root, "net"))
    File.ln_s!("/proc/net/tcp", Path.join(proc_root, "net/tcp"))
    File.ln_s!("/proc/net/tcp6", Path.join(proc_root, "net/tcp6"))
    config = ctx.config |> Map.put("port", port) |> Map.put(:proc_root, proc_root)
    assert {:ok, blocked} = Watchdog.step(config, "check")
    assert blocked["phase"] == "blocked"
    assert blocked["last_action"]["reason"] =~ "port occupied"
    assert blocked["versions"] == %{}
  end

  @tag timeout: 120_000
  test "a packaged fixed installation restarts without interactive credential input", ctx do
    {build, 0} =
      System.cmd("timeout", ["--signal=KILL", "90s", "mix", "escript.build"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert build =~ "symphony" or build == ""
    controller = Path.expand("bin/symphony")
    install = Path.join([ctx.root, "releases", "packaged"])
    File.mkdir_p!(Path.join(install, "bin"))
    executable = Path.join(install, "bin/symphony")
    File.cp!(controller, executable)
    File.chmod!(executable, 0o755)

    File.write!(
      ctx.config["workflow"],
      """
      ---
      tracker:
        kind: github
        provider:
          repo: example/example
          token: $GITHUB_TOKEN
        required_labels: [ready]
        active_states: [open]
        terminal_states: [closed]
      polling:
        interval_ms: 600000
      workspace:
        root: #{Path.join(ctx.root, "workspaces")}
      mvp:
        enabled: false
      ---
      Offline packaged runner probe.
      """
    )

    config = %{ctx.config | "controller" => controller, "backoff_ms" => 50}
    credential_info = File.stat!(config["credential_file"])
    assert credential_info.uid == File.stat!("/proc/self").uid
    assert Bitwise.band(credential_info.mode, 0o077) == 0
    assert Bitwise.band(File.stat!(ctx.root).mode, 0o077) == 0
    pointer!(config, "packaged", install)
    assert {:ok, first} = Watchdog.step(config, "start")
    assert first["process"]["install"] == install
    first_pid = first["process"]["pid"]
    assert File.read!("/proc/#{first_pid}/environ") =~ "GITHUB_TOKEN=test-token"
    kill_group(first_pid, config["workflow"], "-KILL")
    wait_absent(first_pid)
    Process.sleep(60)

    assert {:ok, second} = Watchdog.step(config, "check")
    assert second["process"]["pid"] != first_pid
    assert second["versions"]["packaged"]["attempts"] == 2
    assert File.read!("/proc/#{second["process"]["pid"]}/environ") =~ "GITHUB_TOKEN=test-token"
    refute File.read!(config["status_file"]) =~ "test-token"
    refute File.read!(Path.join(config["state_dir"], "history.jsonl")) =~ "test-token"
  end

  @tag timeout: 120_000
  test "packaged manual starts share a lock; killing the watchdog leaves its runner alive", ctx do
    {output, status} =
      System.cmd("timeout", ["--signal=KILL", "90s", "mix", "escript.build"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    controller = Path.expand("bin/symphony")
    config = ctx.config |> Map.put("controller", controller) |> Map.put("backoff_ms", 50)
    config_path = Path.join(ctx.root, "watchdog.json")
    File.write!(config_path, Jason.encode!(config))

    {status_json, 0} = System.cmd(controller, ["--watchdog", "status", config_path])
    assert Jason.decode!(status_json)["phase"] == "new"

    missing_controller = Path.join(ctx.root, "missing-controller")
    File.write!(config_path, Jason.encode!(%{config | "controller" => missing_controller}))

    {missing, 1} =
      System.cmd(controller, ["--watchdog", "status", config_path], stderr_to_stdout: true)

    assert missing =~ "controller executable missing"
    missing_state = config["status_file"] |> File.read!() |> Jason.decode!()
    assert missing_state["last_action"]["reason"] == "controller executable missing"
    assert List.last(history(config))["reason"] == "controller executable missing"

    child = Path.join(ctx.root, "child-controller")
    File.write!(child, "#!/bin/sh\nprintf '%s\\n' 'child failed'\nexit 7\n")
    File.chmod!(child, 0o755)
    File.write!(config_path, Jason.encode!(%{config | "controller" => child}))

    {failed, 1} =
      System.cmd(controller, ["--watchdog", "status", config_path], stderr_to_stdout: true)

    assert failed =~ "watchdog child failed with exit 7"

    assert Jason.decode!(File.read!(config["status_file"]))["last_action"]["reason"] ==
             "watchdog child failed with exit 7"

    File.write!(child, "#!/bin/sh\nprintf '%s\\n' 'not-json'\n")

    {malformed, 1} =
      System.cmd(controller, ["--watchdog", "status", config_path], stderr_to_stdout: true)

    assert malformed =~ "watchdog: invalid watchdog child response"
    assert List.last(history(config))["reason"] == "invalid watchdog child response"

    File.write!(child, "#!/bin/sh\nprintf '%s\\n' '[]'\n")

    {wrong_shape, 1} =
      System.cmd(controller, ["--watchdog", "status", config_path], stderr_to_stdout: true)

    assert wrong_shape =~ "watchdog: invalid watchdog child response"

    File.write!(child, "#!/bin/sh\nprintf '%s\\n' '{}'\n")

    {empty_object, 1} =
      System.cmd(controller, ["--watchdog", "status", config_path], stderr_to_stdout: true)

    assert empty_object =~ "watchdog: invalid watchdog child response"
    assert List.last(history(config))["reason"] == "invalid watchdog child response"
    File.write!(config_path, Jason.encode!(config))

    {usage, 1} = System.cmd(controller, ["--watchdog"], stderr_to_stdout: true)
    assert usage =~ "Usage: symphony --watchdog"

    {invalid, 1} =
      System.cmd(controller, ["--watchdog", "status", "missing.json"], stderr_to_stdout: true)

    assert invalid =~ "invalid or unreadable watchdog config"

    {invalid_internal, 1} =
      System.cmd(controller, ["--watchdog-once", "start", "missing.json"], stderr_to_stdout: true)

    assert invalid_internal =~ "invalid or unreadable watchdog config"

    {denied, 1} =
      System.cmd(controller, ["--watchdog-once", "start", config_path],
        stderr_to_stdout: true,
        env: [{"SYMPHONY_WATCHDOG_INTERNAL", nil}]
      )

    assert denied =~ "requires the service lock"

    {forged, 1} =
      System.cmd(controller, ["--watchdog-once", "start", config_path],
        stderr_to_stdout: true,
        env: [{"SYMPHONY_WATCHDOG_INTERNAL", "1"}]
      )

    assert forged =~ "requires the service lock"

    lock_path = Path.join(config["state_dir"], "start.lock")
    unrelated_lock = Path.join(ctx.root, "unrelated.lock")

    {unrelated, 1} =
      System.cmd(
        "flock",
        ["-x", unrelated_lock, controller, "--watchdog-once", "status", config_path],
        stderr_to_stdout: true
      )

    assert unrelated =~ "requires the service lock"

    {unlocked_descriptor, 1} =
      System.cmd(
        "sh",
        [
          "-c",
          "exec 9>\"$1\"; shift; exec \"$@\"",
          "watchdog-test",
          lock_path,
          controller,
          "--watchdog-once",
          "status",
          config_path
        ],
        stderr_to_stdout: true
      )

    assert unlocked_descriptor =~ "requires the service lock"

    {locked, 0} =
      System.cmd(
        "flock",
        ["-x", lock_path, controller, "--watchdog-once", "status", config_path]
      )

    assert Jason.decode!(locked)["phase"] == "blocked"
    assert File.exists?(config["status_file"])

    tasks =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              System.cmd(controller, ["--watchdog", "start", config_path], stderr_to_stdout: true)
            end)

    for task <- tasks do
      {result, exit_code} = Task.await(task, 15_000)
      assert exit_code == 0, result
    end

    state = config["status_file"] |> File.read!() |> Jason.decode!()
    assert state["versions"]["v1"]["attempts"] == 1
    pid = state["process"]["pid"]

    {raw_pid, 0} =
      System.cmd("sh", [
        "-c",
        "\"$@\" >/dev/null 2>&1 & echo $!",
        "watchdog-test",
        controller,
        "--watchdog",
        "run",
        config_path
      ])

    {watchdog_pid, ""} = raw_pid |> String.trim() |> Integer.parse()

    on_exit(fn ->
      case File.read("/proc/#{watchdog_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, config_path),
            do: System.cmd("kill", ["-KILL", Integer.to_string(watchdog_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end
    end)

    Process.sleep(100)
    assert File.read!("/proc/#{watchdog_pid}/cmdline") =~ config_path
    System.cmd("kill", ["-KILL", Integer.to_string(watchdog_pid)])

    assert File.exists?("/proc/#{pid}")
    {restarted, 0} = System.cmd(controller, ["--watchdog", "start", config_path])
    assert Jason.decode!(restarted)["process"]["pid"] == pid
    assert Jason.decode!(restarted)["versions"]["v1"]["attempts"] == 1

    slow_controller = Path.join(ctx.root, "slow-controller")
    child_started = Path.join(ctx.root, "child-started")
    child_result = Path.join(ctx.root, "child-result")
    child_output = Path.join(ctx.root, "child-output")

    File.write!(
      slow_controller,
      "#!/bin/sh\nprintf started > '#{child_started}'\nsleep 0.2\n" <>
        "'#{controller}' \"$@\" > '#{child_output}' 2>&1\nresult=$?\n" <>
        "printf '%s\\n' \"$result\" > '#{child_result}'\n" <>
        "cat '#{child_output}'\nexit \"$result\"\n"
    )

    File.chmod!(slow_controller, 0o755)
    # The 200 ms child delay is inside each check. Leave room for the packaged
    # VM and flock startup so this test measures the loop period, not boot time.
    timed_config = %{config | "controller" => slow_controller, "interval_ms" => 1_500}
    File.write!(config_path, Jason.encode!(timed_config))
    prior_checks = restarted |> Jason.decode!() |> Map.fetch!("history_count")

    {new_watchdog_raw, 0} =
      System.cmd("sh", [
        "-c",
        "\"$@\" >/dev/null 2>&1 & echo $!",
        "watchdog-test",
        controller,
        "--watchdog",
        "run",
        config_path
      ])

    {new_watchdog_pid, ""} = new_watchdog_raw |> String.trim() |> Integer.parse()

    on_exit(fn ->
      case File.read("/proc/#{new_watchdog_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, config_path),
            do: System.cmd("kill", ["-KILL", Integer.to_string(new_watchdog_pid)])

        _ ->
          :ok
      end
    end)

    first_check =
      wait_check(
        timed_config,
        prior_checks,
        new_watchdog_pid,
        child_started,
        child_result,
        child_output
      )

    killed_at = System.system_time(:millisecond)
    kill_group(pid, config["workflow"])
    wait_absent(pid)
    exit_event = wait_exit_event(config, prior_checks, timed_config["interval_ms"])
    assert exit_event["at"] - first_check["at"] <= timed_config["interval_ms"] + 100
    assert exit_event["at"] - killed_at <= timed_config["interval_ms"] + 100
    replacement = wait_replacement(config["status_file"], pid)
    assert replacement["versions"]["v1"]["attempts"] == 2
    assert replacement["process"]["pid"] != pid
  end

  defp install!(root, version, body) do
    install = Path.join([root, "releases", version])
    File.mkdir_p!(Path.join(install, "bin"))
    executable = Path.join(install, "bin/symphony")
    File.write!(executable, "#!/bin/sh\n#{body}\n")
    File.chmod!(executable, 0o755)
    install
  end

  defp controlled_proc_config(ctx) do
    proc_root = Path.join(ctx.root, "controlled-proc")
    boot_file = Path.join(proc_root, "sys/kernel/random/boot_id")
    File.mkdir_p!(Path.dirname(boot_file))
    File.cp!("/proc/sys/kernel/random/boot_id", boot_file)

    ctx.config
    |> Map.put(:proc_root, proc_root)
    |> Map.put(:spawn_command, fn command, args, options ->
      spawn_with_proc_link(proc_root, command, args, options)
    end)
  end

  defp spawn_with_proc_link(proc_root, command, args, options) do
    result = System.cmd(command, args, options)
    if match?({_, 0}, result), do: link_spawned_pid(proc_root, elem(result, 0))
    result
  end

  defp link_spawned_pid(proc_root, output) do
    case Integer.parse(String.trim(output)) do
      {pid, ""} -> File.ln_s!("/proc/#{pid}", Path.join(proc_root, Integer.to_string(pid)))
      _ -> :ok
    end
  end

  defp pointer!(config, version, install) do
    File.write!(
      config["pointer_file"],
      Jason.encode!(%{"version" => version, "install" => install})
    )
  end

  defp history(config) do
    config["state_dir"]
    |> Path.join("history.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp assert_audit_complete(config) do
    state = config["status_file"] |> File.read!() |> Jason.decode!()
    entries = history(config)
    assert state["history_count"] == length(entries)

    for entry <- entries do
      assert is_integer(entry["at"])
      assert is_binary(entry["action"])
      assert is_binary(entry["reason"])
      assert is_binary(entry["phase"])
      assert entry["pointer"]["version"] in ["v1", "v2"]
      assert Map.has_key?(entry, "observed")

      if entry["observed"] do
        assert is_integer(entry["observed"]["pid"])
        assert is_binary(entry["observed"]["version"])
        assert is_binary(entry["observed"]["boot_id"])
        assert is_binary(entry["observed"]["start_ticks"])
        assert is_binary(entry["observed"]["install"])
      end
    end

    latest = List.last(entries)
    assert state["last_action"] == Map.take(latest, ["at", "action", "reason"])
    assert state["pointer"] == latest["pointer"]
  end

  defp change_state(config, fun) do
    path = Path.join(config["state_dir"], "status.json")
    state = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(state))
    audit = Path.join(config["state_dir"], "history.jsonl")
    entries = audit |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    [last | earlier] = Enum.reverse(entries)
    last = last |> Map.merge(Map.take(state, ~w(pointer process observed phase))) |> Map.put("state", state)
    updated = Enum.reverse([last | earlier])
    File.write!(audit, Enum.map_join(updated, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp kill_group(pid, workflow, signal \\ "-TERM") do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, command} ->
        if String.contains?(command, workflow) and String.contains?(command, "symphony") do
          System.cmd("kill", [signal, "--", "-#{pid}"], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end
  end

  defp wait_absent(pid, remaining \\ 50)
  defp wait_absent(_pid, 0), do: flunk("runner did not exit")

  defp wait_absent(pid, remaining) do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        :ok

      {:error, :esrch} ->
        :ok

      {:ok, stat} ->
        if String.contains?(stat, ") Z ") do
          :ok
        else
          Process.sleep(20)
          wait_absent(pid, remaining - 1)
        end
    end
  end

  defp wait_file(path, remaining \\ 50)
  defp wait_file(_path, 0), do: flunk("runner did not write its credential probe")

  defp wait_file(path, remaining) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_file(path, remaining - 1)
    end
  end

  defp wait_replacement(path, old_pid, remaining \\ 100)
  defp wait_replacement(_path, _old_pid, 0), do: flunk("watchdog loop did not relaunch runner")

  defp wait_replacement(path, old_pid, remaining) do
    state = path |> File.read!() |> Jason.decode!()

    if is_map(state["process"]) and state["process"]["pid"] != old_pid do
      state
    else
      Process.sleep(50)
      wait_replacement(path, old_pid, remaining - 1)
    end
  end

  defp wait_check(config, prior_count, watchdog_pid, child_started, child_result, child_output) do
    deadline = System.monotonic_time(:millisecond) + 10_000

    poll_check(
      config,
      prior_count,
      watchdog_pid,
      child_started,
      child_result,
      child_output,
      deadline
    )
  end

  defp poll_check(config, prior_count, watchdog_pid, child_started, child_result, child_output, deadline) do
    entries = history(config)
    check = entries |> Enum.drop(prior_count) |> Enum.find(&(&1["action"] == "check"))

    case {check, File.read(child_result)} do
      {check, {:ok, "0\n"}} when is_map(check) ->
        check

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          cmdline = File.read("/proc/#{watchdog_pid}/cmdline")
          status = File.read(config["status_file"])

          flunk(
            "watchdog loop did not complete a check; pid=#{watchdog_pid} " <>
              "cmdline=#{inspect(cmdline)} status=#{inspect(status)} " <>
              "child_started=#{inspect(File.read(child_started))} " <>
              "child_exit=#{inspect(File.read(child_result))} " <>
              "child_output=#{inspect(File.read(child_output))} " <>
              "recent_audit=#{inspect(Enum.take(entries, -5))}"
          )
        end

        Process.sleep(20)
        poll_check(config, prior_count, watchdog_pid, child_started, child_result, child_output, deadline)
    end
  end

  defp wait_exit_event(config, prior_count, interval_ms) do
    deadline = System.monotonic_time(:millisecond) + interval_ms + 5_000
    poll_exit_event(config, prior_count, deadline)
  end

  defp poll_exit_event(config, prior_count, deadline) do
    case config |> history() |> Enum.drop(prior_count) |> Enum.find(&(&1["action"] == "exit")) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "watchdog loop did not observe runner exit; " <>
              "recent_audit=#{inspect(Enum.take(history(config), -5))}"
          )
        end

        Process.sleep(20)
        poll_exit_event(config, prior_count, deadline)

      event ->
        event
    end
  end

  defp check_after_quick_exit(config) do
    state = check_after_transient_scan(config)

    case state["process"] do
      %{"pid" => pid} ->
        wait_absent(pid)
        check_after_transient_scan(config)

      nil ->
        state
    end
  end

  defp check_after_transient_scan(config, remaining \\ 5)

  defp check_after_transient_scan(config, remaining) do
    assert {:ok, state} = Watchdog.step(config, "check")

    if state["last_action"]["reason"] == "process table identity inaccessible" and remaining > 0 do
      assert state["phase"] == "blocked"
      Process.sleep(20)
      check_after_transient_scan(config, remaining - 1)
    else
      state
    end
  end

  defp proc_stat(pid, status) do
    "#{pid} (runner) #{status} " <> Enum.join(List.duplicate("0", 18) ++ ["123"], " ")
  end
end
