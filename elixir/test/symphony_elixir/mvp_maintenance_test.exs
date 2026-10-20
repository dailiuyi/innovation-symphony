defmodule SymphonyElixir.Mvp.MaintenanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.Maintenance

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    settings = %{state_dir: root, execution_readiness: %{enabled: true, required_backend: "vm"}}
    state = %{running: %{}, retry_attempts: %{}, poll_check_in_progress: false}
    %{root: root, settings: settings, state: state}
  end

  test "maintenance is separate from the new-intake-only pause", c do
    File.write!(Path.join(c.root, "intake-paused"), "ordinary disk pause")
    assert Maintenance.open(c.settings) == :ok
    assert Maintenance.snapshot(c.settings, c.state) == nil
    File.write!(Maintenance.path(c.settings), Jason.encode!(%{"nonce" => String.duplicate("a", 32)}))
    assert Maintenance.open(c.settings) == {:error, :mvp_maintenance_paused}
    snapshot = Maintenance.snapshot(c.settings, c.state)
    assert %{acknowledged: true, drained: true, nonce: nonce, pid: pid, boot_id: boot} = snapshot
    assert nonce == String.duplicate("a", 32)
    assert pid == String.to_integer(System.pid())
    assert String.trim(File.read!("/proc/sys/kernel/random/boot_id")) == boot
    assert Maintenance.open(%{}) == :ok
    assert Maintenance.snapshot(%{}, c.state) == nil
  end

  test "in-flight polling, workers and retries cannot acknowledge a drained controller", c do
    File.write!(Maintenance.path(c.settings), Jason.encode!(%{"nonce" => String.duplicate("b", 32)}))

    busy_states = [
      %{c.state | running: %{job: true}},
      %{c.state | retry_attempts: %{job: true}},
      %{c.state | poll_check_in_progress: true}
    ]

    for state <- busy_states do
      assert %{acknowledged: true, drained: false} = Maintenance.snapshot(c.settings, state)
    end
  end

  test "unknown markers fence dispatch but cannot authorize maintenance shutdown", c do
    marker = Maintenance.path(c.settings)

    for bytes <- ["broken", "[]", "{}", Jason.encode!(%{"nonce" => "wrong"}), String.duplicate("x", 4097)] do
      File.write!(marker, bytes)
      assert {:error, :mvp_maintenance_paused} = Maintenance.open(c.settings)
      assert %{acknowledged: false, drained: false} = Maintenance.snapshot(c.settings, c.state)
    end

    File.rm!(marker)
    File.ln_s!(Path.join(c.root, "missing"), marker)
    assert {:error, :mvp_maintenance_paused} = Maintenance.open(c.settings)
    assert %{acknowledged: false, drained: false} = Maintenance.snapshot(c.settings, c.state)
    File.rm!(marker)
    File.mkdir!(marker)
    assert %{acknowledged: false, drained: false} = Maintenance.snapshot(c.settings, c.state)
  end

  test "configuration errors do not create an affirmative drain acknowledgement" do
    File.write!(Workflow.workflow_file_path(), "---\nmvp: broken\n---\n")
    assert {:error, _} = WorkflowStore.force_reload()
    assert Maintenance.current_snapshot(%{}) == nil
  end
end
