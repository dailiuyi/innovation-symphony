defmodule SymphonyElixir.WatchdogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Watchdog

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-watchdog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
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
    File.write!(config_path, Jason.encode!(ctx.config))
    assert {:ok, _} = Watchdog.load_config(config_path)

    File.rm!(ctx.config["pointer_file"])
    assert {:ok, state} = Watchdog.step(ctx.config, "check")
    assert state["phase"] == "blocked"
    assert state["versions"] == %{}
    assert state["last_action"]["reason"] =~ "pointer"

    for malformed <- ["not json", ~s({"version":"../v1","install":"/missing"}), ~s({"version":"v1","install":"/missing/v1"})] do
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
    install!(ctx.root, "v1", "printf '%s' \"$GITHUB_TOKEN\" > '#{injected}'\nwhile :; do sleep 1; done")
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
    assert {:ok, no_status_port} = Watchdog.step(Map.put(ctx.config, "port", 1), "check")
    assert no_status_port["process"]["pid"] == pid

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

  test "identity conflict and missing record fail closed", ctx do
    assert {:ok, started} = Watchdog.step(ctx.config, "start")
    pid = started["process"]["pid"]
    change_state(ctx.config, fn state -> put_in(state, ["process", "start_ticks"], "reused") end)
    assert {:ok, conflict} = Watchdog.step(ctx.config, "check")
    assert conflict["phase"] == "blocked"
    assert conflict["last_action"]["reason"] =~ "identity conflict"
    assert conflict["process"]["pid"] == pid

    change_state(ctx.config, fn state -> Map.put(state, "process", nil) end)
    assert {:ok, unrecorded} = Watchdog.step(ctx.config, "check")
    assert unrecorded["phase"] == "blocked"
    assert unrecorded["last_action"]["reason"] =~ "unrecorded runner"
    assert File.exists?("/proc/#{pid}")
    kill_group(pid, ctx.config["workflow"])
  end

  test "a recorded PID reused by an unrelated process is not treated as this runner", ctx do
    assert {:ok, started} = Watchdog.step(ctx.config, "start")
    kill_group(started["process"]["pid"], ctx.config["workflow"])
    wait_absent(started["process"]["pid"])
    {raw_pid, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    {unrelated_pid, ""} = raw_pid |> String.trim() |> Integer.parse()

    on_exit(fn ->
      case File.read("/proc/#{unrelated_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, "sleep"), do: System.cmd("kill", [Integer.to_string(unrelated_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end
    end)

    change_state(ctx.config, fn state -> put_in(state, ["process", "pid"], unrelated_pid) end)

    assert {:ok, blocked} = Watchdog.step(ctx.config, "check")
    assert blocked["phase"] == "blocked"
    assert blocked["versions"]["v1"]["attempts"] == 1
    assert File.exists?("/proc/#{unrelated_pid}")
  end

  test "failed starts back off, exhaust per-version budget and require explicit recovery", ctx do
    install!(ctx.root, "v1", "exit 2")
    assert {:ok, first} = Watchdog.step(ctx.config, "check")
    assert first["versions"]["v1"]["attempts"] == 1
    assert first["phase"] == "backoff"
    assert {:ok, waiting} = Watchdog.step(ctx.config, "check")
    assert waiting["phase"] == "backoff"
    assert waiting["versions"]["v1"]["attempts"] == 1

    change_state(ctx.config, fn state -> put_in(state, ["versions", "v1", "next_at"], 0) end)
    assert {:ok, second} = Watchdog.step(ctx.config, "check")
    assert second["versions"]["v1"]["attempts"] == 2
    assert {:ok, exhausted} = Watchdog.step(ctx.config, "check")
    assert exhausted["phase"] == "awaiting_human"
    assert exhausted["versions"]["v1"]["awaiting_human"]
    assert {:ok, still_exhausted} = Watchdog.step(ctx.config, "check")
    assert still_exhausted["versions"]["v1"]["attempts"] == 2
    assert {:ok, _} = Watchdog.step(ctx.config, "pause")
    assert {:ok, resumed} = Watchdog.step(ctx.config, "resume")
    assert resumed["versions"]["v1"]["awaiting_human"]
    assert {:ok, after_resume} = Watchdog.step(ctx.config, "check")
    assert after_resume["phase"] == "awaiting_human"

    install2 = install!(ctx.root, "v2", "exit 0")
    pointer!(ctx.config, "v2", install2)
    assert {:ok, other} = Watchdog.step(ctx.config, "check")
    assert other["versions"]["v2"]["attempts"] == 1
    assert other["phase"] == "backoff"
    pointer!(ctx.config, "v1", ctx.install)
    assert {:ok, old} = Watchdog.step(ctx.config, "check")
    assert old["phase"] == "awaiting_human"

    previous = old["history_count"]
    assert {:ok, recovered} = Watchdog.step(ctx.config, "recover")
    assert recovered["versions"]["v1"]["attempts"] == 0
    assert recovered["history_count"] == previous + 1
    assert {:ok, retried} = Watchdog.step(ctx.config, "check")
    assert retried["versions"]["v1"]["attempts"] == 1
  end

  test "pause persists through state reload and recovery does not clear it", ctx do
    File.mkdir_p!(ctx.config["state_dir"])
    File.write!(ctx.config["maintenance_file"], "external maintenance")
    assert {:ok, externally_paused} = Watchdog.step(ctx.config, "check")
    assert externally_paused["phase"] == "paused"
    assert externally_paused["versions"] == %{}

    assert {:ok, paused} = Watchdog.step(ctx.config, "pause")
    assert paused["paused"]
    assert {:ok, next} = Watchdog.step(ctx.config, "check")
    assert next["phase"] == "paused"
    assert next["versions"] == %{}
    assert {:ok, recovered} = Watchdog.step(ctx.config, "recover")
    assert recovered["paused"]
    assert {:ok, resumed} = Watchdog.step(ctx.config, "resume")
    refute resumed["paused"]
    assert {:ok, started} = Watchdog.step(ctx.config, "check")
    assert started["phase"] == "running"
  end

  test "corrupt state is never treated as a fresh budget", ctx do
    assert {:ok, _} = Watchdog.step(ctx.config, "pause")
    File.write!(Path.join(ctx.config["state_dir"], "status.json"), ~s({"paused":false,"versions":{"v1":{"attempts":"bad"}}}))
    assert {:error, reason} = Watchdog.step(ctx.config, "check")
    assert reason =~ "refusing to reset budget"
  end

  test "unrelated listener blocks a launch without consuming budget", ctx do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, {_address, port}} = :inet.sockname(socket)
    config = Map.put(ctx.config, "port", port)
    assert {:ok, blocked} = Watchdog.step(config, "check")
    assert blocked["phase"] == "blocked"
    assert blocked["last_action"]["reason"] =~ "port occupied"
    assert blocked["versions"] == %{}
  end

  @tag timeout: 120_000
  test "packaged manual starts share a lock; killing the watchdog leaves its runner alive", ctx do
    {output, status} = System.cmd("timeout", ["--signal=KILL", "90s", "mix", "escript.build"], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
    assert status == 0, output
    controller = Path.expand("bin/symphony")
    config = Map.put(ctx.config, "controller", controller)
    config_path = Path.join(ctx.root, "watchdog.json")
    File.write!(config_path, Jason.encode!(config))

    {denied, 1} = System.cmd(controller, ["--watchdog-once", "start", config_path], stderr_to_stdout: true, env: [{"SYMPHONY_WATCHDOG_INTERNAL", nil}])
    assert denied =~ "requires the service lock"

    tasks = for _ <- 1..2, do: Task.async(fn -> System.cmd(controller, ["--watchdog", "start", config_path], stderr_to_stdout: true) end)

    for task <- tasks do
      {result, exit_code} = Task.await(task, 15_000)
      assert exit_code == 0, result
    end

    state = config["status_file"] |> File.read!() |> Jason.decode!()
    assert state["versions"]["v1"]["attempts"] == 1
    pid = state["process"]["pid"]

    {raw_pid, 0} = System.cmd("sh", ["-c", "\"$@\" >/dev/null 2>&1 & echo $!", "watchdog-test", controller, "--watchdog", "run", config_path])
    {watchdog_pid, ""} = raw_pid |> String.trim() |> Integer.parse()

    on_exit(fn ->
      case File.read("/proc/#{watchdog_pid}/cmdline") do
        {:ok, command} ->
          if String.contains?(command, config_path), do: System.cmd("kill", ["-KILL", Integer.to_string(watchdog_pid)], stderr_to_stdout: true)

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
  end

  defp install!(root, version, body) do
    install = Path.join([root, "releases", version])
    File.mkdir_p!(Path.join(install, "bin"))
    executable = Path.join(install, "bin/symphony")
    File.write!(executable, "#!/bin/sh\n#{body}\n")
    File.chmod!(executable, 0o755)
    install
  end

  defp pointer!(config, version, install) do
    File.write!(config["pointer_file"], Jason.encode!(%{"version" => version, "install" => install}))
  end

  defp history(config) do
    config["state_dir"] |> Path.join("history.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp change_state(config, fun) do
    path = Path.join(config["state_dir"], "status.json")
    path |> File.read!() |> Jason.decode!() |> fun.() |> Jason.encode!() |> then(&File.write!(path, &1))
  end

  defp kill_group(pid, workflow) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, command} ->
        if String.contains?(command, workflow) and String.contains?(command, "symphony") do
          System.cmd("kill", ["-TERM", "--", "-#{pid}"], stderr_to_stdout: true)
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
end
