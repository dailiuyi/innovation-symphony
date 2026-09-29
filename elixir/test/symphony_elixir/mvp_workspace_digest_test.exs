defmodule SymphonyElixir.Mvp.WorkspaceDigestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Commands, Executor}

  test "digest binds staged and unstaged content, executable mode, links, deletion and ignored source" do
    root = workspace!()
    File.write!(Path.join(root, "tracked"), "base")
    File.write!(Path.join(root, ".gitignore"), "ignored-source\nelixir/_build/\n")
    Commands.git!(["add", "."], root)
    Commands.git!(["commit", "-m", "base"], root)
    original = digest!(root)

    File.write!(Path.join(root, "tracked"), "changed")
    changed = digest!(root)
    refute changed == original
    Commands.git!(["add", "tracked"], root)
    staged = digest!(root)
    refute staged == changed
    File.chmod!(Path.join(root, "tracked"), 0o755)
    executable = digest!(root)
    refute executable == staged
    File.rm!(Path.join(root, "tracked"))
    deleted = digest!(root)
    refute deleted == executable
    File.ln_s!("target-one", Path.join(root, "tracked"))
    linked = digest!(root)
    refute linked == deleted
    File.ln_s!("target-two", Path.join(root, "untracked-link"))
    refute digest!(root) == linked
    File.write!(Path.join(root, "ignored-source"), "preserve me")
    preserved = digest!(root)
    File.write!(Path.join(root, "ignored-source"), "changed ignored source")
    refute digest!(root) == preserved
    File.mkdir_p!(Path.join(root, "elixir/_build"))
    before_build = digest!(root)
    File.write!(Path.join(root, "elixir/_build/cache"), "irrelevant cache")
    assert digest!(root) == before_build

    for directory <- ["bin", "node_modules", "deps", "_build", "cover"] do
      File.mkdir_p!(Path.join(root, directory))
      before_source = digest!(root)
      File.write!(Path.join([root, directory, "source"]), "must remain bound")
      refute digest!(root) == before_source
    end
  end

  test "index visibility flags and whitespace paths cannot hide modified source" do
    root = workspace!()
    path = Path.join(root, " leading-space")
    before_file = digest!(root)
    File.write!(path, "original")
    refute digest!(root) == before_file
    Commands.git!(["add", " leading-space"], root)
    Commands.git!(["commit", "-m", "whitespace path"], root)

    for flag <- ["--assume-unchanged", "--skip-worktree"] do
      Commands.git!(["update-index", flag, " leading-space"], root)
      before_change = digest!(root)
      File.write!(path, flag)
      refute digest!(root) == before_change
    end
  end

  test "hashes files across chunks and rejects oversized or special entries without reading their bodies" do
    root = workspace!()
    source = Path.join(root, "large")
    File.write!(source, String.duplicate("a", 2_100_000))
    original = digest!(root)
    File.write!(source, String.duplicate("a", 2_099_999) <> "b")
    refute digest!(root) == original
    {_, 0} = System.cmd("truncate", ["-s", "8589934593", source])
    assert {:error, :mvp_recovery_workspace_digest_unavailable} = Executor.workspace_digest(root)
    File.rm!(source)
    File.write!(source, "tracked")
    Commands.git!(["add", "large"], root)
    Commands.git!(["commit", "-m", "track file"], root)
    File.rm!(source)
    {_, 0} = System.cmd("mkfifo", [source])
    assert {:error, :mvp_recovery_workspace_digest_unavailable} = Executor.workspace_digest(root)
    assert {:error, :mvp_recovery_workspace_digest_unavailable} = Executor.workspace_digest(Path.dirname(root))
  end

  defp workspace! do
    root = Path.join(System.tmp_dir!(), "workspace-digest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Commands.git!(["init", "--initial-branch=main"], root)
    Commands.git!(["commit", "--allow-empty", "-m", "base"], root)
    root
  end

  defp digest!(root) do
    {:ok, digest} = Executor.workspace_digest(root)
    digest
  end
end
