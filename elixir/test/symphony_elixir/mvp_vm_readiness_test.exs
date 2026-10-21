defmodule SymphonyElixir.Mvp.VmReadinessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ModelServicesFixture, as: F
  alias SymphonyElixir.Mvp
  alias SymphonyElixir.Mvp.Commands
  alias SymphonyElixir.Mvp.ExecutionReadiness
  alias SymphonyElixir.Mvp.Executor
  alias SymphonyElixir.Mvp.Intake
  alias SymphonyElixir.Mvp.Maintenance
  alias SymphonyElixir.Mvp.ModelCatalog
  alias SymphonyElixir.Mvp.ModelServices
  alias SymphonyElixir.Mvp.Receipt
  alias SymphonyElixir.Mvp.RestartRecovery
  alias SymphonyElixir.Mvp.VmReadiness

  @uuid "e95ff885-dd31-4ad7-b894-35d1a0102429"
  @config %{
    "enabled" => true,
    "required_backend" => "vm",
    "required_acceptances" => [],
    "vm_uuid" => @uuid,
    "capability_probes" => %{"admin" => ["/usr/bin/sudo", "-n", "true"], "docker" => ["/usr/bin/docker", "info"]}
  }

  setup do
    root = Path.dirname(Workflow.workflow_file_path())

    for key <- ~w(GH12_CODER_KEY GH12_REVIEWER_KEY) do
      previous = System.get_env(key)
      System.put_env(key, "synthetic-vm-readiness-only")
      on_exit(fn -> restore_env(key, previous) end)
    end

    native = System.get_env("SYMPHONY_TEST_CODEX") || "/opt/codex"
    settings = F.settings(Path.join(root, "state")) |> Map.put(:model_command, "#{inspect(native)} app-server")

    registry =
      Enum.reduce([:coder, :reviewer], settings.model_services, fn role, registry ->
        {:ok, service} = ModelServices.default_snapshot(%{settings | model_services: registry}, role, "fixture")
        {:ok, registry} = ModelCatalog.attest(registry, service, F.proof(role))
        registry
      end)

    settings = %{settings | model_services: registry}
    {:ok, readiness} = ExecutionReadiness.settings(@config)

    settings =
      Map.merge(settings, %{
        enabled: true,
        ready_label: "ready",
        checks: [["true"]],
        execution_readiness: readiness,
        sandbox: %{enabled: false},
        execution_workspace_root: Path.join(root, "workspaces"),
        workflow_path: Workflow.workflow_file_path(),
        secret_environment_names: []
      })

    for path <- [settings.execution_workspace_root, Path.join(root, "sandboxes")], do: File.mkdir_p!(path)

    config = %{
      "tracker" => %{"kind" => "github", "provider" => %{"repo" => "owner/repo", "token" => "synthetic"}, "required_labels" => ["ready"], "active_states" => ["open"], "terminal_states" => ["closed"]},
      "workspace" => %{"root" => settings.execution_workspace_root},
      "agent" => %{"max_concurrent_agents" => 1},
      "codex" => %{"command" => settings.model_command, "approval_policy" => "never", "thread_sandbox" => "danger-full-access", "turn_sandbox_policy" => %{"type" => "dangerFullAccess"}},
      "mvp" => %{
        "enabled" => true,
        "ready_label" => "ready",
        "checks" => [["true"]],
        "state_dir" => settings.state_dir,
        "coder_model" => "gpt-test",
        "reviewer_model" => "gpt-test",
        "allowed_models" => ["gpt-test"],
        "allowed_actors" => ["owner"],
        "sandbox" => %{"enabled" => false},
        "execution_readiness" => @config,
        "model_services" => settings.model_services
      }
    }

    File.write!(settings.workflow_path, "---\n#{Jason.encode!(config)}\n---\nVM readiness fixture")
    :ok = WorkflowStore.force_reload()
    {:ok, settings} = Config.mvp_settings()
    {:ok, models} = Intake.resolve_comments([], settings)
    issue = %Issue{id: "VM-1", identifier: "GH-1", state: "open", labels: ["ready"], native_ref: %{"kind" => "github", "repo" => "owner/repo", "number" => 1}}
    %{settings: settings, models: models, issue: issue, root: root, native: native}
  end

  defp probe(["systemd-detect-virt", "--container"], _, _), do: {:error, {:command_failed, 1, "none\n"}}
  defp probe(["systemd-detect-virt", "--vm"], _, _), do: {:ok, "kvm\n"}
  defp probe(["sudo", "-n", "cat", "/sys/class/dmi/id/product_uuid"], _, _), do: {:ok, String.upcase(@uuid) <> "\n"}
  defp probe(["/usr/bin/sudo", "-n", "true"], _, _), do: {:ok, ""}
  defp probe(["/usr/bin/docker", "info"], _, _), do: {:ok, "synthetic daemon available"}
  defp probe(["stat", "-f", "-c", "%T %a %S", "--", _], _, _), do: {:ok, "ext2/ext3 1310720 4096\n"}
  defp probe(["findmnt", "-n", "-o", "OPTIONS", "--target", _], _, _), do: {:ok, "rw,relatime\n"}
  defp probe([binary, "--version"], cwd, timeout), do: Commands.run([binary, "--version"], cwd, timeout, secret_environment_names: [])

  defp role_options(context, role), do: {:ok, [model_service: context.services[Atom.to_string(role)]]}

  defp request("GET", path, _, nil, _) do
    body = if String.ends_with?(path, "/events"), do: [%{"id" => 1, "event" => "labeled", "label" => %{"name" => "ready"}, "actor" => %{"login" => "owner"}}], else: []
    {:ok, %{status: 200, body: body}}
  end

  test "VM configuration is strict and never accepts an implicit or unbound host mode" do
    assert {:ok, %{required_backend: "vm", vm_uuid: @uuid}} = ExecutionReadiness.settings(@config)

    for bad <- [
          Map.delete(@config, "vm_uuid"),
          Map.put(@config, "vm_uuid", "host"),
          Map.put(@config, "vm_uuid", nil),
          Map.put(@config, "vm_uuid", "00000000-0000-0000-0000-000000000000"),
          Map.put(@config, "extra", true),
          Map.put(@config, "required_acceptances", ["linux"]),
          put_in(@config, ["capability_probes", "docker"], "docker info"),
          put_in(@config, ["capability_probes", "admin"], ["sudo", "-n", "true"]),
          put_in(@config, ["capability_probes", "admin"], ["/usr/bin/true", "bad\nargument"]),
          Map.put(@config, "capability_probes", %{})
        ] do
      assert {:error, :invalid_execution_readiness} = ExecutionReadiness.settings(bad)
    end
  end

  test "maintenance acknowledgement binds the actual workflow and fences dispatch without changing authorization", c do
    nonce = String.duplicate("a", 32)
    File.write!(Maintenance.path(c.settings), Jason.encode!(%{"nonce" => nonce}))
    state = %{running: %{}, retry_attempts: %{}, poll_check_in_progress: false}
    assert %{nonce: ^nonce, acknowledged: true, drained: true} = Maintenance.current_snapshot(state)
    refute Mvp.available?(c.issue)
    assert {:error, :mvp_maintenance_paused} = Mvp.dispatch_readiness(c.issue)
    assert :ok = Mvp.run(c.issue, self(), c.settings, request_fun: fn _, _, _, _, _ -> flunk("maintenance must not dispatch") end)
    assert_receive {:codex_worker_update, "VM-1", %{message: ":mvp_maintenance_paused"}}
    refute Receipt.exists?(c.settings, c.issue)
    assert {:ok, %{enabled: true}} = Config.mvp_settings()
  end

  test "runtime accepts unrestricted execution only with explicit VM and disabled task sandbox", %{settings: settings} do
    runtime = Config.settings!()
    assert :ok = Mvp.validate_runtime(runtime, settings)

    for bad <- [
          put_in(settings, [:execution_readiness, :enabled], false),
          put_in(settings, [:execution_readiness, :required_backend], "rootless"),
          %{settings | sandbox: %{enabled: true}},
          Map.delete(settings, :execution_readiness)
        ] do
      assert {:error, _} = Mvp.validate_runtime(runtime, bad)
    end

    for bad <- [
          put_in(runtime.codex.approval_policy, "on-request"),
          put_in(runtime.codex.thread_sandbox, "workspace-write"),
          put_in(runtime.codex.turn_sandbox_policy, nil),
          put_in(runtime.codex.turn_sandbox_policy, %{"type" => "dangerFullAccess", "extra" => true}),
          put_in(runtime.agent.max_concurrent_agents, 2),
          put_in(runtime.worker.ssh_hosts, ["remote"])
        ] do
      assert {:error, _} = Mvp.validate_runtime(bad, settings)
    end

    legacy = %{runtime | codex: %{runtime.codex | approval_policy: %{}, thread_sandbox: "workspace-write", turn_sandbox_policy: nil}}
    assert :ok = Mvp.validate_runtime(legacy, %{})
    assert {:error, _} = Mvp.validate_runtime(legacy, settings)
  end

  test "readiness verifies both registered roles, native CLI, VM and all durable roots without claiming", c do
    assert {:ok, report} = ExecutionReadiness.check(c.settings, c.models, vm_readiness_command_run: &probe/3)
    assert report["backend"] == "vm"
    assert report["vm_uuid"] == @uuid
    assert report["formal_acceptance"] == false
    assert length(report["directories"]) == 3
    assert Enum.all?(report["directories"], &(&1["free_bytes"] == 5 * 1024 * 1024 * 1024))
    assert byte_size(report["services_sha256"]) == 64
    assert :ok = ExecutionReadiness.defaults(c.settings, vm_readiness_command_run: &probe/3)
    refute Receipt.exists?(c.settings, c.issue)
  end

  test "bare host, wrong UUID, unreadable kernel identity and nested container never fall back", c do
    for {argv, failure} <- [
          {["systemd-detect-virt", "--vm"], {:ok, "none\n"}},
          {["systemd-detect-virt", "--vm"], {:error, {:command_failed, 1, "none\n"}}},
          {["systemd-detect-virt", "--container"], {:ok, "docker\n"}},
          {["sudo", "-n", "cat", "/sys/class/dmi/id/product_uuid"], {:ok, "11111111-1111-1111-1111-111111111111"}},
          {["sudo", "-n", "cat", "/sys/class/dmi/id/product_uuid"], {:error, {:command_failed, 1, "permission denied"}}}
        ] do
      runner = fn args, cwd, timeout -> if args == argv, do: failure, else: probe(args, cwd, timeout) end
      assert {:error, :execution_readiness_vm_identity_mismatch} = VmReadiness.check(c.settings, vm_readiness_command_run: runner)
      assert_no_claim(c, runner, "execution_readiness_vm_identity_mismatch")
    end
  end

  test "missing Docker or administrator capability refuses before receipt, workspace hooks or model", c do
    for {argv, name} <- [{["/usr/bin/docker", "info"], "docker"}, {["/usr/bin/sudo", "-n", "true"], "admin"}] do
      failure = {:error, {:command_failed, 127, "unavailable"}}
      runner = fn args, cwd, timeout -> if args == argv, do: failure, else: probe(args, cwd, timeout) end
      assert {:error, {:execution_readiness_vm_capability, ^name}} = VmReadiness.check(c.settings, vm_readiness_command_run: runner)
      assert_no_claim(c, runner, "execution_readiness_vm_capability")
    end
  end

  test "administrator may require additional named tool probes and every one gates admission", c do
    config = put_in(@config, ["capability_probes", "java"], ["/usr/bin/java", "-version"])
    config = put_in(config, ["capability_probes", "python"], ["/usr/bin/python3", "--version"])
    assert {:ok, readiness} = ExecutionReadiness.settings(config)
    settings = %{c.settings | execution_readiness: readiness}

    runner = fn
      ["/usr/bin/java", "-version"], _, _ ->
        send(self(), :java_probed)
        {:ok, "synthetic java"}

      ["/usr/bin/python3", "--version"], _, _ ->
        send(self(), :python_probed)
        {:ok, "synthetic python"}

      argv, cwd, timeout ->
        probe(argv, cwd, timeout)
    end

    assert {:ok, _} = VmReadiness.check(settings, vm_readiness_command_run: runner)
    assert_received :java_probed
    assert_received :python_probed

    runner = fn
      ["/usr/bin/java", "-version"], _, _ -> {:error, {:command_failed, 127, "missing"}}
      argv, cwd, timeout -> probe(argv, cwd, timeout)
    end

    assert {:error, {:execution_readiness_vm_capability, "java"}} = VmReadiness.check(settings, vm_readiness_command_run: runner)
    assert_no_claim(%{c | settings: settings}, runner, "execution_readiness_vm_capability")
  end

  test "less than 5 GiB, volatile filesystem and read-only mounts block admission", c do
    for output <- ["ext2/ext3 1310719 4096", "tmpfs 9999999 4096", "overlayfs 9999999 4096", "ext4 invalid 4096"] do
      runner = fn
        ["stat" | _], _, _ -> {:ok, output}
        args, cwd, timeout -> probe(args, cwd, timeout)
      end

      assert {:error, {:execution_readiness_vm_storage, _}} = VmReadiness.check(c.settings, vm_readiness_command_run: runner)
      assert_no_claim(c, runner, "execution_readiness_vm_storage")
    end

    runner = fn
      ["findmnt" | _], _, _ -> {:ok, "ro,relatime"}
      args, cwd, timeout -> probe(args, cwd, timeout)
    end

    assert_no_claim(c, runner, "execution_readiness_vm_storage")
  end

  test "missing, mode-unwritable and overlapping persistent directories fail read-only", c do
    missing = %{c.settings | execution_workspace_root: Path.join(c.root, "missing")}
    assert {:error, {:execution_readiness_vm_directory, _}} = VmReadiness.check(missing, vm_readiness_command_run: &probe/3)
    refute File.exists?(missing.execution_workspace_root)
    File.chmod!(c.settings.execution_workspace_root, 0o500)
    assert {:error, {:execution_readiness_vm_directory, _}} = VmReadiness.check(c.settings, vm_readiness_command_run: &probe/3)
    File.chmod!(c.settings.execution_workspace_root, 0o700)
    overlap = %{c.settings | execution_workspace_root: c.settings.state_dir}
    assert {:error, :execution_readiness_vm_directory_overlap} = VmReadiness.check(overlap, vm_readiness_command_run: &probe/3)
    loop = Path.join(c.root, "loop")
    File.ln_s!(loop, loop)
    assert {:error, {:execution_readiness_vm_directory, ^loop}} = VmReadiness.check(%{c.settings | execution_workspace_root: loop}, vm_readiness_command_run: &probe/3)
  end

  test "unverified or unavailable models and a nonnative CLI cannot claim or invoke models", c do
    for role <- ~w(coder reviewer) do
      service = c.models.services[role]
      binding = ModelServices.binding(service)
      registry = Map.update!(c.settings.model_services, "validations", &Map.delete(&1, binding))
      settings = %{c.settings | model_services: registry}

      assert {:error, {:execution_readiness_role, _, :model_role_not_verified}} =
               ExecutionReadiness.check(settings, c.models,
                 vm_readiness_command_run: &probe/3,
                 readiness_role_options: &role_options/2
               )

      assert_no_claim(%{c | settings: settings}, &probe/3, "model_role_not_verified")
    end

    runner = fn
      [_, "--version"], _, _ -> {:ok, "codex-cli 0.163.1"}
      args, cwd, timeout -> probe(args, cwd, timeout)
    end

    assert_no_claim(c, runner, "native_client_mismatch")
    key = System.get_env("GH12_REVIEWER_KEY")
    System.delete_env("GH12_REVIEWER_KEY")
    assert_no_claim(c, &probe/3, "model_credential_missing")
    System.put_env("GH12_REVIEWER_KEY", key)
  end

  test "actual owner read/write access cannot substitute for directory search permission", c do
    assert {uid, 0} = System.cmd("id", ["-u"])
    assert String.trim(uid) != "0", "run the permission regression as a nonroot user"
    path = c.settings.execution_workspace_root
    File.chmod!(path, 0o601)
    on_exit(fn -> File.chmod!(path, 0o700) end)
    assert {:ok, %{access: :read_write}} = File.stat(path)
    assert {_, 1} = System.cmd("/usr/bin/test", ["-x", path])
    assert {:error, {:execution_readiness_vm_directory, ^path}} = VmReadiness.check(c.settings, vm_readiness_command_run: &probe/3)
    assert_no_claim(c, &probe/3, "execution_readiness_vm_directory")
    assert {:ok, []} = File.ls(path)
  end

  test "a script advertising the pinned version cannot stand in for the native app server", c do
    script = Path.join(c.root, "fake-codex")
    marker = Path.join(c.root, "fake-codex-ran")
    File.write!(script, "#!/bin/sh\nprintf ran > #{inspect(marker)}\nif [ \"$1\" = --version ]; then echo codex-cli 0.163.0; else exit 127; fi\n")
    File.chmod!(script, 0o700)
    assert {:error, :native_client_mismatch} = VmReadiness.native_client(c.settings, script, [])
    refute File.exists?(marker)
    assert {:error, :native_client_mismatch} = VmReadiness.native_client(c.settings, "/usr/bin/true", [])
    assert {:error, :native_client_unavailable} = VmReadiness.native_client(c.settings, Path.join(c.root, "missing-codex"), [])
  end

  test "native CLI resolves symlinks and PATH to the verified ELF and exact pinned version", c do
    assert :ok = VmReadiness.native_client(c.settings, c.native, [])
    name = "verified-codex-#{System.unique_integer([:positive])}"
    link = Path.join(c.root, name)
    File.ln_s!(c.native, link)
    original = System.get_env("PATH")
    System.put_env("PATH", "#{c.root}:#{original}")
    on_exit(fn -> restore_env("PATH", original) end)
    assert :ok = VmReadiness.native_client(c.settings, name, [])
    runner = fn [_, "--version"], _, _ -> {:ok, "codex-cli 0.163.1"} end
    options = [vm_readiness_command_run: runner]
    assert {:error, :native_client_mismatch} = VmReadiness.native_client(c.settings, link, options)
  end

  test "intake marker blocks new dispatch and claims while frozen readiness remains usable", c do
    assert Mvp.available?(c.issue)
    marker = ExecutionReadiness.intake_pause_path(c.settings)
    File.write!(marker, "operator maintenance")
    refute Mvp.available?(c.issue)
    assert {:error, :mvp_intake_paused} = Mvp.dispatch_readiness(c.issue)
    assert {:ok, _} = ExecutionReadiness.check(c.settings, c.models, vm_readiness_command_run: &probe/3)
    assert :ok = Mvp.run(c.issue, self(), c.settings, request_fun: fn _, _, _, _, _ -> flunk("paused intake must not read forge") end)
    assert_receive {:codex_worker_update, "VM-1", %{message: ":mvp_intake_paused"}}
    refute Receipt.exists?(c.settings, c.issue)
    File.rm!(marker)
    assert Mvp.available?(c.issue)
    File.ln_s!(Path.join(c.root, "nonexistent"), marker)
    assert {:error, :mvp_intake_paused} = ExecutionReadiness.intake_open(c.settings)
  end

  test "default runtime probing refuses a different VM identity without bridge overrides", c do
    settings = put_in(c.settings, [:execution_readiness, :vm_uuid], "11111111-1111-1111-1111-111111111111")
    assert {:error, :execution_readiness_vm_identity_mismatch} = VmReadiness.check(settings)
    refute Receipt.exists?(c.settings, c.issue)
  end

  test "an inaccessible pause directory is unknown and closes intake", c do
    File.chmod!(c.settings.state_dir, 0o600)

    try do
      assert {:error, {:mvp_intake_pause_unreadable, :eacces}} = ExecutionReadiness.intake_open(c.settings)
    after
      File.chmod!(c.settings.state_dir, 0o700)
    end

    assert :ok = ExecutionReadiness.intake_open(c.settings)
  end

  test "frozen role snapshots do not authorize execution without their service registry", c do
    settings = %{c.settings | model_services: nil}
    opts = [vm_readiness_command_run: &probe/3, readiness_role_options: &role_options/2]

    assert {:error, {:execution_readiness_role, :coder, :model_services_not_configured}} =
             ExecutionReadiness.check(settings, c.models, opts)

    refute Receipt.exists?(settings, c.issue)
  end

  test "executable but unreadable native input is an IO failure before version execution", c do
    path = Path.join(c.root, "unreadable-native")
    File.write!(path, <<127, "ELF", 0, 0, 0, 0>>)
    File.chmod!(path, 0o100)
    assert System.find_executable(path) == path
    assert {:error, :eacces} = File.read(path)
    runner = fn _, _, _ -> flunk("unreadable native input cannot reach version execution") end
    opts = [vm_readiness_command_run: runner]
    assert {:error, :native_client_unavailable} = VmReadiness.native_client(c.settings, path, opts)
  end

  test "closing a native file descriptor during hashing refuses admission before execution", c do
    :erlang.trace_pattern({IO, :binread, 2}, true, [:local])

    task =
      Task.async(fn ->
        receive do
          :hash -> VmReadiness.native_client(c.settings, c.native, [])
        end
      end)

    :erlang.trace(task.pid, true, [:call])

    try do
      send(task.pid, :hash)
      assert_receive {:trace, pid, :call, {IO, :binread, [file, 1_048_576]}}, 5_000
      assert pid == task.pid
      :erlang.suspend_process(pid)
      :ok = File.close(file)
      :erlang.resume_process(pid)
      assert {:error, :native_client_unavailable} = Task.await(task, 5_000)
    after
      :erlang.trace_pattern({IO, :binread, 2}, false, [:local])
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "invalid command environment snapshots fail closed without crashing the controller", c do
    settings = %{c.settings | secret_environment_names: [nil]}
    assert {:error, :native_client_unavailable} = VmReadiness.native_client(settings, c.native, [])
    assert Process.alive?(self())
  end

  test "an exited version process with inherited stdout cannot hold readiness indefinitely", c do
    tools = Path.join(c.root, "held-version-tools")
    File.mkdir!(tools)
    release = Path.join(c.root, "release-version-holder")
    holder = Path.join(c.root, "version-holder.pid")
    timeout = Path.join(tools, "timeout")

    File.write!(timeout, """
    #!/usr/bin/python3
    import os, pathlib, subprocess, sys, time
    subprocess.run(sys.argv[3:], check=True)
    if os.fork() == 0:
        pathlib.Path(#{inspect(holder)}).write_text(str(os.getpid()))
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and not pathlib.Path(#{inspect(release)}).exists():
            time.sleep(0.01)
        os._exit(0)
    os._exit(0)
    """)

    File.chmod!(timeout, 0o700)
    original = System.get_env("PATH")
    System.put_env("PATH", "#{tools}:#{original}")

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, :native_client_unavailable} = VmReadiness.native_client(c.settings, c.native, [])
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 35_000 and elapsed < 40_000
      assert File.exists?("/proc/#{String.trim(File.read!(holder))}")
    after
      System.put_env("PATH", original)
      File.write!(release, "release test process")
    end
  end

  test "fresh and resumed VM preparation bind Git fetch to the original remaining budget", c do
    c = restart_fixture(c)
    assert_receive {:restart_model, :coder}
    {:ok, workflow} = Workflow.load(c.settings.workflow_path)
    config = put_in(workflow.config, ["mvp", "recovery", "max_elapsed_ms"], 3_600_000)
    File.write!(c.settings.workflow_path, "---\n#{Jason.encode!(config)}\n---\nVM fetch budget fixture")
    :ok = WorkflowStore.force_reload()
    {:ok, settings} = Config.mvp_settings()
    log = Path.join(c.root, "fetch-timeouts.jsonl")
    tools = Path.join(c.root, "fetch-tools")
    File.mkdir!(tools)

    File.write!(Path.join(tools, "timeout"), """
    #!/usr/bin/python3
    import json, os, sys
    with open(#{inspect(log)}, 'a') as output:
        output.write(json.dumps(sys.argv[1:]) + '\\n')
    os.execv('/usr/bin/timeout', ['timeout', *sys.argv[1:]])
    """)

    File.chmod!(Path.join(tools, "timeout"), 0o700)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "#{tools}:#{previous_path}")

    try do
      for {mode, number} <- [{:fresh, 2}, {:resumed, 3}] do
        id = "VM-FETCH-#{mode}"
        issue = %{c.issue | id: id, identifier: "GH-#{number}", native_ref: Map.put(c.issue.native_ref, "number", number)}
        receipt_path = Receipt.path(settings, issue)

        if mode == :resumed do
          workspace = Path.join(settings.execution_workspace_root, Workspace.workspace_key(issue))
          File.mkdir!(workspace)
          {:ok, ^receipt_path} = Receipt.claim(settings, issue)
          assert :ok = RestartRecovery.freeze(receipt_path, issue, settings, c.models)
          data = Receipt.read(receipt_path)
          started = DateTime.utc_now() |> DateTime.add(-3_540_000, :millisecond) |> DateTime.to_iso8601()
          frozen = Map.put(data["restart_recovery"], "started_at", started)
          Receipt.update(receipt_path, "preparing", %{"restart_recovery" => frozen})
          mark_previous_owner_dead(receipt_path)
          File.write!(ExecutionReadiness.intake_pause_path(settings), "pause additional intake")
        end

        original_started = if mode == :resumed, do: Receipt.read(receipt_path)["restart_recovery"]["started_at"]
        assert :ok = Mvp.run(issue, self(), settings, restart_options(c))
        assert_receive {:codex_worker_update, ^id, %{event: :turn_input_required, message: message}}
        assert message =~ "awaiting_human_merge"
        receipt = Receipt.read(receipt_path)
        assert receipt["status"] == "awaiting_human"
        assert receipt["recovery"]["started_at"] == receipt["restart_recovery"]["started_at"]
        if mode == :resumed, do: assert(receipt["recovery"]["started_at"] == original_started)
        assert receipt["recovery"]["agent_attempts"] == 2
      end

      [fresh, resumed] = log |> File.stream!() |> Enum.map(&Jason.decode!/1) |> Enum.filter(&Enum.member?(&1, "fetch"))
      {fresh_seconds, ""} = fresh |> Enum.at(1) |> String.trim_trailing("s") |> Float.parse()
      {resumed_seconds, ""} = resumed |> Enum.at(1) |> String.trim_trailing("s") |> Float.parse()
      assert fresh_seconds > 120 and fresh_seconds <= 1_800
      assert resumed_seconds > 0 and resumed_seconds <= 60
    after
      System.put_env("PATH", previous_path)
    end
  end

  test "Mvp resumes a frozen completed coder through checking while new intake is paused", c do
    c = restart_fixture(c)
    before = Receipt.read(c.receipt)
    File.write!(ExecutionReadiness.intake_pause_path(c.settings), "pause new claims only")
    assert Mvp.available?(c.issue)
    assert :ok = Mvp.run(c.issue, self(), c.settings, restart_options(c))
    assert_receive {:codex_worker_update, "VM-1", %{event: :turn_input_required, message: message}}
    assert message =~ "awaiting_human_merge"
    after_resume = Receipt.read(c.receipt)
    assert after_resume["status"] == "awaiting_human"
    assert after_resume["models"] == before["models"]
    assert after_resume["services"] == before["services"]
    assert after_resume["restart_recovery"]["generation"] == 1
    assert after_resume["recovery"]["agent_attempts"] == 2
    assert_received {:restart_model, :coder}
    refute_received {:restart_model, :coder}
    assert_received {:restart_model, :reviewer}
    refute_received {:restart_model, :reviewer}
    assert_received :restart_published
    refute_received :restart_published
  end

  test "restart rechecks ready authority, journals revocation and retries only transient reads", c do
    c = restart_fixture(c)
    original = File.read!(c.receipt)
    network = fn "GET", _, _, nil, _ -> {:error, :synthetic_network_failure} end
    opts = Keyword.put(restart_options(c), :request_fun, network)
    assert :ok = Mvp.run(c.issue, self(), c.settings, opts)
    assert_receive {:codex_worker_update, "VM-1", %{message: message}}
    assert message =~ "synthetic_network_failure"
    assert File.read!(c.receipt) == original
    refute File.exists?(c.receipt <> ".restart-blocked.json")
    assert RestartRecovery.eligible?(c.receipt, c.settings)

    for failure <- [:unauthorized_actor, :event_removed, :ready_removed] do
      issue = if failure == :ready_removed, do: %{c.issue | labels: []}, else: c.issue
      response = revoked_request(failure)
      opts = Keyword.put(restart_options(c), :request_fun, response)
      assert :ok = Mvp.run(issue, self(), c.settings, opts)
      assert_receive {:codex_worker_update, "VM-1", %{message: message}}
      assert message =~ revocation_reason(failure)
      assert File.read!(c.receipt) == original
      journal = c.receipt <> ".restart-blocked.json"
      assert Jason.decode!(File.read!(journal))["reason"] =~ revocation_reason(failure)
      refute RestartRecovery.eligible?(c.receipt, c.settings)
      File.rm!(journal)
    end

    assert_received {:restart_model, :coder}
    refute_received {:restart_model, _}
    refute_received :restart_published
  end

  test "restart uses frozen services after repository defaults change and maintenance fences it", c do
    c = restart_fixture(c)
    frozen = Receipt.read(c.receipt)["services"]
    {:ok, workflow} = Workflow.load(c.settings.workflow_path)
    defaults = %{"coder" => "reviewing", "reviewer" => "coding"}
    config = put_in(workflow.config, ["mvp", "model_services", "defaults"], defaults)
    File.write!(c.settings.workflow_path, "---\n#{Jason.encode!(config)}\n---\nChanged defaults")
    :ok = WorkflowStore.force_reload()
    {:ok, settings} = Config.mvp_settings()
    assert settings.model_services["defaults"] == defaults
    before = File.read!(c.receipt)
    File.write!(Maintenance.path(settings), Jason.encode!(%{"nonce" => String.duplicate("b", 32)}))
    assert :ok = Mvp.run(c.issue, self(), settings, restart_options(c))
    assert_receive {:codex_worker_update, "VM-1", %{message: ":mvp_maintenance_paused"}}
    assert File.read!(c.receipt) == before
    File.rm!(Maintenance.path(settings))

    request = fn "GET", path, params, nil, tracker ->
      assert String.ends_with?(path, "/events"), "restart must not resolve newer model comments"
      request("GET", path, params, nil, tracker)
    end

    opts = Keyword.put(restart_options(c), :request_fun, request)
    assert :ok = Mvp.run(c.issue, self(), settings, opts)
    assert_receive {:codex_worker_update, "VM-1", %{event: :turn_input_required, message: message}}
    assert message =~ "awaiting_human_merge"
    after_resume = Receipt.read(c.receipt)
    assert after_resume["services"] == frozen
    assert after_resume["services"]["coder"]["id"] == "coding"
    assert after_resume["services"]["reviewer"]["id"] == "reviewing"
  end

  defp revoked_request(:event_removed), do: fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: []}} end

  defp revoked_request(:unauthorized_actor) do
    fn "GET", path, params, nil, tracker ->
      {:ok, response} = request("GET", path, params, nil, tracker)
      events = Enum.map(response.body, &put_in(&1, ["actor", "login"], "unauthorized"))
      {:ok, %{response | body: events}}
    end
  end

  defp revoked_request(:ready_removed), do: fn _, _, _, _, _ -> flunk("withdrawn ready cannot fetch events") end
  defp revocation_reason(:unauthorized_actor), do: "unauthorized_ready_actor"
  defp revocation_reason(:event_removed), do: "ready_label_event_not_found"
  defp revocation_reason(:ready_removed), do: "issue_not_ready"

  defp restart_fixture(c) do
    {:ok, workflow} = Workflow.load(c.settings.workflow_path)
    recovery = %{"enabled" => true, "resume_on_restart" => true, "max_elapsed_ms" => 120_000}
    config = workflow.config |> put_in(["mvp", "recovery"], recovery)
    config = put_in(config, ["mvp", "checks"], [["/usr/bin/test", "-f", "candidate.txt"]])
    File.write!(c.settings.workflow_path, "---\n#{Jason.encode!(config)}\n---\nRestart integration fixture")
    :ok = WorkflowStore.force_reload()
    {:ok, settings} = Config.mvp_settings()
    {:ok, models} = Intake.resolve_comments([], settings)
    issue = %{c.issue | title: "Create candidate", description: "candidate exists"}
    workspace = Path.join(settings.execution_workspace_root, Workspace.workspace_key(issue))
    remote = Path.join(c.root, "restart-origin.git")
    File.mkdir!(workspace)
    Commands.git!(["init", "--bare", remote], c.root)
    Commands.git!(["init"], workspace)
    File.write!(Path.join(workspace, "source.txt"), "base")
    Commands.git!(["add", "."], workspace)
    Commands.git!(["commit", "-m", "base"], workspace)
    Commands.git!(["branch", "-M", "main"], workspace)
    Commands.git!(["push", remote, "main"], workspace)
    {:ok, receipt} = Receipt.claim(settings, issue)
    c = Map.merge(c, %{settings: settings, models: models, issue: issue, workspace: workspace, remote: remote, receipt: receipt})
    opts = Keyword.put(restart_options(c), :on_message, &interrupt_check/1)
    assert catch_throw(Executor.run(workspace, issue, settings, models, receipt, opts)) == :checking_interrupted
    assert Receipt.read(receipt)["status"] == "checking"
    mark_previous_owner_dead(receipt)
    assert RestartRecovery.eligible?(receipt, settings)
    c
  end

  defp interrupt_check(%{event: :mvp_check_started}), do: throw(:checking_interrupted)
  defp interrupt_check(_), do: :ok

  defp restart_options(c) do
    [
      tracker_settings: Config.settings!().tracker,
      repository: fn _, _ -> {:ok, %{repo: "owner/repo", base: "main", url: c.remote}} end,
      request_fun: &request/5,
      vm_readiness_command_run: &probe/3,
      agent: &restart_agent/4,
      publish: fn _, _, _, _, _, receipt, _ ->
        send(self(), :restart_published)
        Receipt.update(receipt, "awaiting_human", %{"pull_request" => "local-draft"})
        {:ok, "local-draft"}
      end
    ]
  end

  defp restart_agent(workspace, _, _, opts) do
    role = if opts[:read_only], do: :reviewer, else: :coder
    send(self(), {:restart_model, role})

    if role == :coder do
      File.write!(Path.join(workspace, "candidate.txt"), "candidate")
      {:ok, %{output_text: "done"}}
    else
      review = %{
        "approved" => true,
        "summary" => "review",
        "blockers" => [],
        "criteria" => [
          %{"acceptance" => "candidate exists", "tests" => ["candidate check"], "assertion_strength" => "checks existence", "failure_sensitivity" => "missing file fails", "adequate" => true}
        ]
      }

      {:ok, %{output_text: Jason.encode!(review)}}
    end
  end

  defp mark_previous_owner_dead(receipt) do
    {stat, 0} = System.cmd("cat", ["/proc/self/stat"])
    [pid, fields] = Regex.run(~r/\A(\d+) \(.*\) (.*)\z/s, String.trim(stat), capture: :all_but_first)
    {:ok, current} = RestartRecovery.owner()
    owner = Map.merge(current, %{"pid" => String.to_integer(pid), "starttime" => Enum.at(String.split(fields), 19)})
    data = Receipt.read(receipt)
    contract = Map.put(data["restart_recovery"], "owner", owner)
    :ok = Receipt.update(receipt, data["status"], %{"restart_recovery" => contract})
  end

  defp assert_no_claim(c, runner, expected) do
    assert :ok = Mvp.run(c.issue, self(), c.settings, request_fun: &request/5, vm_readiness_command_run: runner, repository: fn _, _ -> flunk("must not enter Executor or model path") end)
    assert_receive {:codex_worker_update, "VM-1", %{message: message}}
    assert message =~ expected
    refute Receipt.exists?(c.settings, c.issue)
    refute File.exists?(Path.join(c.settings.execution_workspace_root, Workspace.workspace_key(c.issue)))
    refute_receive {:worker_runtime_info, "VM-1", _}
  end
end
