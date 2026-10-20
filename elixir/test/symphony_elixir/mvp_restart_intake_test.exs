defmodule SymphonyElixir.Mvp.RestartIntakeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Maintenance, Receipt, RestartIntake, RestartRecovery}

  setup do
    root = Path.join(System.tmp_dir!(), "restart-intake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    settings = %{
      state_dir: root,
      ready_label: "ready",
      recovery: %{enabled: true, resume_on_restart: true},
      execution_readiness: %{enabled: true, required_backend: "vm"},
      sandbox: %{enabled: false}
    }

    tracker = %{kind: "gitlab", active_states: ["opened"], provider: %{"repo" => "owner/repo", "api_url" => "https://gitlab.example/api/v4"}}

    issue = %Issue{
      id: "4",
      identifier: "GL-4",
      title: "Restart",
      state: "opened",
      labels: ["ready"],
      native_ref: %{"kind" => "gitlab", "repo" => "owner/repo", "api_url" => tracker.provider["api_url"], "iid" => 4}
    }

    %{root: root, settings: settings, tracker: tracker, issue: issue}
  end

  test "disk receipts omitted by active-state listing are fetched by ID before new work", c do
    file = pending!(c)
    before = File.read!(file)
    next = %{c.issue | id: "5", identifier: "GL-5"}
    fetch = fn ["4"] -> {:ok, [c.issue]} end
    assert {:ok, [old]} = refresh(c, [next], fetch)
    assert old == c.issue
    assert {:ok, [^old]} = refresh(c, [next, c.issue], fetch)
    assert File.read!(file) == before
  end

  test "revoked ready and closed interrupted issues are durably stopped without rewriting receipts", c do
    for change <- [%{labels: []}, %{state: "closed"}] do
      id = if change == %{labels: []}, do: "6", else: "7"
      issue = %{c.issue | id: id}
      local = %{c | issue: issue}
      file = pending!(local)
      raw = File.read!(file)
      fresh = struct!(issue, change)
      assert {:ok, []} = refresh(local, [], fn [^id] -> {:ok, [fresh]} end)
      journal = Jason.decode!(File.read!(file <> ".restart-blocked.json"))
      assert journal["reason"] == ":mvp_restart_ready_revoked"
      assert journal["receipt_before"] == raw
      assert File.read!(file) == raw
      assert {:ok, []} = refresh(local, [], fn _ -> flunk("stopped receipt was fetched again") end)
    end
  end

  test "a living or unprovable previous executor fences all new intake", c do
    {:ok, owner} = RestartRecovery.owner()

    for identity <- [owner, Map.put(owner, "machine_sha256", "unknown")] do
      file = pending!(c, identity)
      assert {:error, {:mvp_restart_intake_fenced, _}} = refresh(c, [c.issue], fn _ -> flunk("owner not dead") end)
      refute File.exists?(file <> ".restart-blocked.json")
      File.rm!(file)
    end
  end

  test "old, terminal, stopped and other-repository receipts never enter restart scanning", c do
    file = pending!(c)
    original = Receipt.read(file)

    variants = [
      Map.delete(original, "restart_recovery"),
      Map.put(original, "status", "awaiting_external"),
      Map.put(original, "repository", "other/repo"),
      Map.put(original, "tracker_kind", "github"),
      Map.put(original, "tracker_api_url", "https://another.example/api/v4")
    ]

    for data <- variants do
      File.write!(file, Jason.encode!(data))
      assert {:ok, []} = refresh(c, [], fn _ -> flunk("excluded receipt") end)
    end

    File.write!(file, Jason.encode!(original))
    File.write!(file <> ".restart-blocked.json", "{}")
    assert {:ok, []} = refresh(c, [], fn _ -> flunk("already stopped") end)
  end

  test "disabled recovery and maintenance do not scan or invoke the tracker", c do
    pending!(c)
    disabled = put_in(c.settings.recovery.resume_on_restart, false)
    assert {:ok, []} = RestartIntake.refresh([], disabled, c.tracker, fn _ -> flunk("disabled") end)
    File.write!(Maintenance.path(c.settings), "maintenance")
    assert {:ok, []} = refresh(c, [], fn _ -> flunk("maintenance") end)
  end

  test "missing or unreadable issues do not authorize new work", c do
    pending!(c)
    assert {:error, :mvp_restart_issue_unavailable} = refresh(c, [], fn _ -> {:ok, []} end)
    assert {:error, :network} = refresh(c, [], fn _ -> {:error, :network} end)
    wrong_scope = %{c.issue | labels: [], native_ref: Map.put(c.issue.native_ref, "repo", "other/repo")}
    assert {:error, :mvp_restart_ready_revoked} = refresh(c, [], fn _ -> {:ok, [wrong_scope]} end)
  end

  test "a malformed receipt or symlink is preserved and fences scanning", c do
    file = pending!(c)

    for raw <- ["broken", "[]"] do
      File.write!(file, raw)
      assert {:error, :mvp_restart_scan_unreadable} = refresh(c, [], fn _ -> flunk("invalid receipt") end)
      assert File.read!(file) == raw
    end

    File.rm!(file)
    File.ln_s!(Path.join(c.root, "missing"), file)
    assert {:error, :mvp_restart_scan_unreadable} = refresh(c, [], fn _ -> flunk("symlink") end)
  end

  defp refresh(c, issues, fetch), do: RestartIntake.refresh(issues, c.settings, c.tracker, fetch)

  defp pending!(c, owner \\ nil) do
    {:ok, current} = RestartRecovery.owner()
    owner = owner || Map.put(current, "starttime", "0")
    {:ok, file} = Receipt.claim(c.settings, c.issue)
    :ok = Receipt.update(file, "checking", %{"restart_recovery" => %{"enabled" => true, "schema" => 1, "owner" => owner}})
    file
  end
end
