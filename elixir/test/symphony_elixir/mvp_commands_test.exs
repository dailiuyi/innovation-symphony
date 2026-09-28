defmodule SymphonyElixir.Mvp.CommandsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Commands, Receipt}

  test "missing timeout fails closed for commands and Git without launching a process" do
    original = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent-symphony-test-path")
      assert {:error, :mvp_requires_gnu_timeout} = Commands.run(["git", "status"], System.tmp_dir!(), 1_000)
      assert {:error, :mvp_requires_gnu_timeout} = Commands.git(["status"], System.tmp_dir!())

      assert_raise RuntimeError, ~r/mvp_requires_gnu_timeout/, fn ->
        Commands.git!(["status"], System.tmp_dir!())
      end
    after
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end
  end

  @tag :unix
  test "a receipt path beyond filesystem limits reports admission failure" do
    root = Path.join(System.tmp_dir!(), "symphony-receipt-limit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    # Each component is valid; the receipt filename alone takes the full path beyond Linux PATH_MAX.
    state_dir = Enum.reduce(1..16, root, fn _, path -> Path.join(path, String.duplicate("a", 250)) end)
    issue = %{id: "1", native_ref: %{"repo" => "owner/repo"}}

    assert {:error, {:mvp_receipt_write, :enametoolong}} = Receipt.claim(%{state_dir: state_dir}, issue)
    assert File.dir?(state_dir)
  end
end
