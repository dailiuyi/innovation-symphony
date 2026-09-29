defmodule SymphonyElixir.Mvp.EscriptTest do
  use ExUnit.Case, async: false

  @fixture_path Path.expand("../fixtures/mvp_escript_probe.ex", __DIR__)

  test "MVP path checks work from a packaged escript in a child VM" do
    root = Path.join(System.tmp_dir!(), "mvp-escript-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    workflow_dir = Path.join(root, "workflows")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(workflow_dir)
    on_exit(fn -> File.rm_rf(root) end)

    escript = Path.join(bin_dir, "symphony-probe")
    build_escript!(escript)

    assert {:ok, output} = run_probe(escript, workflow_dir, "valid", Path.join(root, "state"), Path.join(root, "workspaces"))
    assert output =~ "ESCRIPT_RUNTIME_LIB_DIR=#{escript}/symphony_elixir"
    assert output =~ "MVP_SETTINGS={:ok,"
    assert output =~ "MVP_AVAILABLE=true"

    state_inside_archive = Path.join(bin_dir, "state")
    workspace_inside_archive = Path.join(bin_dir, "workspaces")

    assert {:ok, output} =
             run_probe(escript, workflow_dir, "state-overlap", state_inside_archive, Path.join(root, "safe-workspaces"))

    assert output =~ "MVP_SETTINGS={:error, :mvp_state_runtime_overlap}"
    assert output =~ "MVP_AVAILABLE=false"

    assert {:ok, output} =
             run_probe(escript, workflow_dir, "workspace-overlap", Path.join(root, "safe-state"), workspace_inside_archive)

    assert output =~ "MVP_SETTINGS={:error, :mvp_workspace_runtime_overlap}"
    assert output =~ "MVP_AVAILABLE=false"

    state_alias = Path.join(root, "state-alias")
    workspace_alias = Path.join(root, "workspace-alias")
    File.ln_s!(bin_dir, state_alias)
    File.ln_s!(bin_dir, workspace_alias)

    assert {:ok, output} =
             run_probe(escript, workflow_dir, "state-symlink-overlap", Path.join(state_alias, "nested"), Path.join(root, "safe-workspaces-2"))

    assert output =~ "MVP_SETTINGS={:error, :mvp_state_runtime_overlap}"
    assert output =~ "MVP_AVAILABLE=false"

    assert {:ok, output} =
             run_probe(escript, workflow_dir, "workspace-symlink-overlap", Path.join(root, "safe-state-2"), Path.join(workspace_alias, "nested"))

    assert output =~ "MVP_SETTINGS={:error, :mvp_workspace_runtime_overlap}"
    assert output =~ "MVP_AVAILABLE=false"
  end

  defp build_escript!(path) do
    [{SymphonyElixir.MvpEscriptProbe, probe_beam}] = Code.compile_file(@fixture_path)
    archive_path = path <> ".zip"

    runtime_ebin = Path.join(List.to_string(:code.lib_dir(:elixir)), "ebin")

    app_entries =
      [runtime_ebin | Enum.map(:code.get_path(), &List.to_string/1)]
      |> Enum.filter(&build_ebin?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.app")))
      |> Enum.uniq_by(&Path.basename/1)
      |> Enum.flat_map(&archive_app_entries/1)

    entries =
      [{~c"Elixir.SymphonyElixir.MvpEscriptProbe.beam", probe_beam} | app_entries]

    assert {:ok, _} = :zip.create(String.to_charlist(archive_path), entries)

    script =
      "#!/usr/bin/env escript\n" <>
        "%% Built by mvp_escript_test.exs\n" <>
        "%%! -escript main Elixir.SymphonyElixir.MvpEscriptProbe\n" <>
        File.read!(archive_path)

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp archive_app_entries(app_file) do
    ebin = Path.dirname(app_file)
    app = Path.basename(app_file, ".app")

    ebin
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, [".app", ".beam"]))
    |> Enum.map(fn name ->
      archive_name = Path.join([app, "ebin", name]) |> String.to_charlist()
      {archive_name, File.read!(Path.join(ebin, name))}
    end)
  end

  defp build_ebin?(path) do
    build_path? = Path.split(path) |> Enum.any?(&(&1 == "_build"))
    build_path? or path == Path.join(List.to_string(:code.lib_dir(:elixir)), "ebin")
  end

  defp run_probe(escript, workflow_dir, name, state_dir, workspace_root) do
    workflow_path = Path.join(workflow_dir, "#{name}.md")
    File.write!(workflow_path, workflow(state_dir, workspace_root))

    {output, status} = System.cmd(escript, [workflow_path], stderr_to_stdout: true)

    if status == 0 do
      {:ok, output}
    else
      {:error, {status, output}}
    end
  rescue
    error -> {:error, error}
  end

  defp workflow(state_dir, workspace_root) do
    """
    ---
    tracker:
      kind: github
      provider:
        repo: "owner/repo"
        token: "unused-test-token"
      required_labels: [ready]
      active_states: [open]
      terminal_states: [closed]
    workspace:
      root: #{Jason.encode!(workspace_root)}
    mvp:
      enabled: true
      coder_model: "coder-a"
      reviewer_model: "reviewer-a"
      allowed_models: ["coder-a", "reviewer-a"]
      allowed_actors: ["alice"]
      checks: [["mix", "test"]]
      state_dir: #{Jason.encode!(state_dir)}
    ---

    Probe only. No tracker request, workspace creation, or model call.
    """
  end
end
