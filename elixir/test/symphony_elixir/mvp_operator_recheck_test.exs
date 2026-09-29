defmodule SymphonyElixir.Mvp.OperatorRecheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.OperatorRecheck

  setup do
    root = Path.join(System.tmp_dir!(), "operator-recheck-#{System.unique_integer([:positive])}")
    evidence = Path.join(root, "receipt.json.evidence")
    File.mkdir_p!(evidence)
    data = %{"rounds" => [%{"evidence" => Path.join(evidence, "round-1")}], "status" => "blocked"}
    raw = Jason.encode!(data)
    receipt = Path.join(root, "receipt.json")
    File.write!(receipt, raw)
    context = %{evidence: evidence, receipt: receipt, settings: %{checks: [["true"]]}, issue: %{id: "42"}}

    audit = %{
      "id" => "first",
      "authorization" => "Operator authorization",
      "runtime_version" => String.duplicate("a", 40),
      "command" => ["recheck"],
      "predecessor" => nil,
      "legacy_closures" => []
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, data: data, raw: raw, audit: audit}
  end

  test "raw receipt change during admission releases only the unaccepted operation lock", fixture do
    File.write!(fixture.context.receipt, "changed")
    assert {:error, :mvp_recheck_receipt_changed} = begin(fixture)
    refute File.exists?(Path.join(fixture.context.evidence, "operator-recheck.lock"))
    refute File.exists?(Path.join(fixture.context.evidence, "operator-rechecks"))
  end

  test "legacy and new operations use the same lock, and interrupted legacy execution retains it", fixture do
    context = fixture.context

    assert :result =
             OperatorRecheck.legacy(context, fn ->
               assert {:error, :mvp_recheck_guard_or_audit_mismatch} = begin(fixture)
               :result
             end)

    assert catch_throw(OperatorRecheck.legacy(context, fn -> throw(:interrupted) end)) == :interrupted
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = begin(fixture)
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = OperatorRecheck.legacy(context, fn -> flunk("must not run") end)
  end

  test "legacy entrypoints cannot run after a normally completed new operation", fixture do
    assert {:ok, operation} = begin(fixture)
    assert :ok = OperatorRecheck.complete(operation, {:error, :failed})
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = OperatorRecheck.legacy(fixture.context, fn -> flunk("must not run") end)
  end

  test "head JSON, identity and completion must agree exactly", fixture do
    root = Path.join(fixture.context.evidence, "operator-rechecks")
    File.mkdir_p!(root)

    for head <- ["not json", "[]", "{}", Jason.encode!(%{"id" => "../escape"}), Jason.encode!(%{"id" => 1})] do
      File.write!(Path.join(root, "head.json"), head)
      assert {:error, :mvp_recheck_guard_or_audit_mismatch} = begin(fixture)
    end

    File.rm!(Path.join(root, "head.json"))
    File.mkdir!(Path.join(root, "head.json"))
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = begin(fixture)
    File.rmdir!(Path.join(root, "head.json"))
    assert {:ok, operation} = begin(fixture)
    data = Map.put(fixture.data, "operator_recheck", "first")
    raw = Jason.encode!(data)
    File.write!(fixture.context.receipt, raw)
    :ok = OperatorRecheck.complete(operation, {:error, :failed})
    audit = %{fixture.audit | "id" => "second", "predecessor" => "first"}

    assert {:error, :mvp_recheck_guard_or_audit_mismatch} =
             OperatorRecheck.begin(fixture.context, raw, data, %{audit | "legacy_closures" => [%{}]})

    File.write!(Path.join(operation.directory, "completion.json"), "{}")
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = OperatorRecheck.begin(fixture.context, raw, data, audit)
  end

  test "audit rejects non-maps, absent predecessor and orphaned permanent legacy guards", fixture do
    for audit <- [nil, true, %{fixture.audit | "command" => []}, %{fixture.audit | "predecessor" => "missing"}] do
      assert {:error, :mvp_recheck_guard_or_audit_mismatch} = OperatorRecheck.begin(fixture.context, fixture.raw, fixture.data, audit)
    end

    File.write!(Path.join(fixture.context.evidence, "operator-check-resume.lock"), "keep original")
    assert {:error, :mvp_recheck_guard_or_audit_mismatch} = begin(fixture)
    assert File.read!(Path.join(fixture.context.evidence, "operator-check-resume.lock")) == "keep original"
  end

  test "runtime identity and invocation must be concrete before acquiring the execution lock", fixture do
    invalid = [
      %{"runtime_version" => nil},
      %{"runtime_version" => "not-a-commit"},
      %{"command" => nil},
      %{"command" => [""]},
      %{"command" => [true]},
      %{"diagnostic" => false}
    ]

    for fields <- invalid do
      audit = Map.merge(fixture.audit, fields)

      assert {:error, :mvp_recheck_guard_or_audit_mismatch} =
               OperatorRecheck.begin(fixture.context, fixture.raw, fixture.data, audit)

      refute File.exists?(Path.join(fixture.context.evidence, "operator-recheck.lock"))
    end
  end

  defp begin(fixture), do: OperatorRecheck.begin(fixture.context, fixture.raw, fixture.data, fixture.audit)
end
