defmodule SymphonyElixir.Mvp.ExternalEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.{ExternalHandoff, Receipt}

  setup do
    root = Path.join(System.tmp_dir!(), "external-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "handoff persistence freezes context and refuses missing or unwritable receipts", %{root: root} do
    context = context(root)
    fields = %{"conditions" => [condition("A1")], "source" => "review", "started_at" => DateTime.to_iso8601(DateTime.utc_now())}
    assert {:ok, record, handoff} = ExternalHandoff.write(context, fields, digest("workspace"))
    assert {:ok, ^record} = ExternalHandoff.read(context, handoff)
    assert Receipt.read(context.receipt)["status"] == "awaiting_external"

    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.write(context, %{fields | "conditions" => []}, digest("workspace"))
    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.write(%{context | metadata: %{bad: :value}}, fields, digest("workspace"))
    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.write(%{context | receipt: Path.join(root, "absent.json")}, fields, digest("workspace"))

    # An existing non-directory cannot become the handoff root.
    occupied = Path.join(root, "occupied")
    File.write!(occupied, "retained")
    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.write(%{context | evidence: occupied}, fields, digest("workspace"))
    assert File.read!(occupied) == "retained"

    # /proc permits directory lookup but refuses creation of an immutable record.
    denied = Path.join(root, "denied")
    File.mkdir!(denied)
    File.ln_s!("/proc", Path.join(denied, "external-handoffs"))
    assert {:error, {:mvp_external_handoff_write, _}} = ExternalHandoff.write(%{context | evidence: denied}, fields, digest("workspace"))
  end

  test "handoff reads reject pointer tampering, wrong hashes, malformed records and invalid context", %{root: root} do
    context = context(root)
    fields = %{"conditions" => [condition("A1")]}
    assert {:ok, _record, handoff} = ExternalHandoff.write(context, fields, digest("workspace"))
    assert {:error, :mvp_external_handoff_mismatch} = ExternalHandoff.read(context, Map.put(handoff, "record_sha256", digest("wrong")))
    assert {:error, :mvp_external_handoff_mismatch} = ExternalHandoff.read(context, Map.put(handoff, "record_path", context.receipt))
    assert {:error, :mvp_external_handoff_mismatch} = ExternalHandoff.read(context, nil)
    assert {:error, :mvp_external_handoff_mismatch} = ExternalHandoff.read(%{}, handoff)
    File.write!(handoff["record_path"], "not json")
    assert {:error, :mvp_external_handoff_mismatch} = ExternalHandoff.read(context, Map.put(handoff, "record_sha256", digest("not json")))
  end

  test "Git metadata accepts binary snapshots and rejects unbound values" do
    assert {:ok, %{"config" => "AAE=", "absent" => nil}} =
             ExternalHandoff.encode_git_metadata(%{"config" => {:ok, <<0, 1>>}, "absent" => {:error, :enoent}})

    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.encode_git_metadata(%{"config" => {:error, :eacces}})
    assert {:error, :mvp_external_handoff_invalid} = ExternalHandoff.encode_git_metadata(nil)
  end

  test "evidence validation rejects wrong coverage, stale proof, invalid hashes and non-regular sources", %{root: root} do
    entry = entry(root, "A1", "signed proof")
    conditions = [condition("A1")]
    assert :ok = ExternalHandoff.validate_evidence(conditions, [entry], [])

    for supplied <- [nil, [nil], [entry, entry], [%{entry | "acceptance" => "A2"}], [Map.put(entry, "extra", true)], [%{entry | "sha256" => digest("other")}]] do
      assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, supplied, [])
    end

    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [entry], [[entry]])
    renamed_history = %{entry | "acceptance" => "Earlier wording of this acceptance"}
    renamed_replay = ExternalHandoff.validate_evidence(conditions, [entry], [[renamed_history]])
    assert {:error, :mvp_external_evidence_invalid} = renamed_replay
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [entry], [[nil]])
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [entry], nil)
    directory = %{entry | "path" => root}
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [directory], [])

    linked = Path.join(root, "linked")
    File.ln_s!(entry["path"], linked)
    linked_source = %{entry | "path" => linked}
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [linked_source], [])

    File.rm!(entry["path"])
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, [entry], [])
  end

  test "evidence snapshots enforce individual and total byte limits", %{root: root} do
    large = entry(root, "A1", :binary.copy("x", 10 * 1_024 * 1_024 + 1))
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence([condition("A1")], [large], [])

    entries = for index <- 1..4, do: entry(root, "A#{index}", :binary.copy("y", 9 * 1_024 * 1_024))
    conditions = Enum.map(1..4, &condition("A#{&1}"))
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.validate_evidence(conditions, entries, [])
  end

  test "copying uses an exclusive audit directory and rejects an occupied destination", %{root: root} do
    entry = entry(root, "A1", "signed proof")
    conditions = [condition("A1")]
    assert {:ok, [copied]} = ExternalHandoff.copy_evidence(root, conditions, [entry], [])
    assert File.read!(copied["path"]) == "signed proof"
    assert copied["sha256"] == entry["sha256"]
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.copy_evidence(root, conditions, [entry], [])
    assert {:error, :mvp_external_evidence_invalid} = ExternalHandoff.copy_evidence(nil, conditions, [entry], [])
  end

  test "a destination collision during evidence import fails without overwriting the interfering file", %{root: root} do
    entry = entry(root, "A1", :binary.copy("z", 10 * 1_024 * 1_024))
    conditions = [condition("A1")]
    directory = Path.join(root, "external-evidence")
    target = Path.join(directory, "evidence-1.bin")
    importer = Task.async(fn -> ExternalHandoff.copy_evidence(root, conditions, [entry], []) end)
    await_directory(directory, System.monotonic_time(:millisecond) + 5_000)
    File.write!(target, "interfering file", [:exclusive])
    assert {:error, :mvp_external_evidence_invalid} = Task.await(importer, 10_000)
    assert File.read!(target) == "interfering file"
  end

  defp await_directory(path, deadline) do
    cond do
      File.dir?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("evidence importer did not create its audit directory")

      true ->
        Process.sleep(1)
        await_directory(path, deadline)
    end
  end

  defp context(root) do
    receipt = Path.join(root, "receipt.json")
    File.write!(receipt, Jason.encode!(%{"recovery" => %{"started_at" => "2026-09-30T00:00:00Z"}}))

    %{
      receipt: receipt,
      evidence: receipt <> ".evidence",
      base: String.duplicate("a", 40),
      branch: "codex/external-evidence",
      repository: %{repo: "owner/repo", base: "main", url: "local"},
      issue: %{id: "5", native_ref: %{"repo" => "owner/repo"}, title: "Verify the feed", description: "A1"},
      workspace: root,
      models: %{coder: "coder", reviewer: "reviewer"},
      limit: 2,
      settings: %{checks: ["mix test"], recovery: %{enabled: true}, sandbox: %{enabled: false}},
      metadata: %{},
      baseline_digest: :crypto.hash(:sha256, "baseline")
    }
  end

  defp condition(acceptance) do
    %{"acceptance" => acceptance, "kind" => "external_condition", "reason" => "Feed unavailable", "required_evidence" => "Signed feed result", "handoff" => "Operator supplies the feed proof"}
  end

  defp entry(root, acceptance, bytes) do
    path = Path.join(root, "proof-#{acceptance}.bin")
    File.write!(path, bytes)
    %{"acceptance" => acceptance, "path" => path, "sha256" => digest(bytes)}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
