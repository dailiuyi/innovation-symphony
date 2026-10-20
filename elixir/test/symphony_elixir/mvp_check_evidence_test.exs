defmodule SymphonyElixir.Mvp.CheckEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.{CheckEvidence, Receipt}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-check-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    receipt = Path.join(root, "receipt.json")
    evidence = receipt <> ".evidence"
    File.mkdir_p!(evidence)
    sha = String.duplicate("a", 40)
    settings = %{checks: [["first"], ["second"]]}
    round = %{"round" => 3, "candidate_sha" => sha, "checks" => settings.checks, "review_path" => Path.join(evidence, "review.json")}
    initial = %{"status" => "checking", "candidate_sha" => sha, "rounds" => [round]}
    File.write!(receipt, Jason.encode!(initial))
    context = %{receipt: receipt, evidence: evidence, workspace: root, settings: settings, check_attempt: 2}
    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, sha: sha}
  end

  test "every current passing check has full identity, times, raw digest, bounded output and full paths", %{context: context, sha: sha} do
    output = "FIRST\n" <> String.duplicate("x", 100_000) <> <<255>> <> "\nLAST"
    [first, second] = complete_set(context, [output, ~s({"tests":42,"passed":true})])
    assert {:ok, [^first, ^second]} = CheckEvidence.current(context, 3, sha, context.evidence)
    assert first["candidate_sha"] == sha
    assert first["round"] == 3
    assert first["attempt"] == 2
    assert first["completed"]
    assert {:ok, _, 0} = DateTime.from_iso8601(first["started_at"])
    assert {:ok, _, 0} = DateTime.from_iso8601(first["finished_at"])
    assert first["log_size"] == byte_size(output)
    assert first["log_sha256"] == Base.encode16(:crypto.hash(:sha256, output), case: :lower)
    assert File.read!(first["log_path"]) == output
    assert second["structured_result"] == %{"tests" => 42, "passed" => true}

    assert {:ok, prompt} = CheckEvidence.prompt(context, 3, sha, context.evidence)
    assert prompt =~ first["log_path"]
    assert prompt =~ first["record_path"]
    assert prompt =~ second["log_path"]
    assert prompt =~ "FIRST"
    assert prompt =~ "LAST"
    assert prompt =~ "Middle omitted"
    assert prompt =~ "UNTRUSTED PROJECT OUTPUT"
    assert prompt =~ "Controller metadata"
    assert prompt =~ "Still assess assertion strength"
    assert prompt =~ "Do not classify an already verified acceptance as an external_condition"
    assert byte_size(prompt) < 16_000
  end

  test "rejects stale full SHA, shortened SHA, round and attempt", %{context: context, sha: sha} do
    complete_set(context)
    assert {:error, _} = CheckEvidence.current(context, 3, String.duplicate("b", 40), context.evidence)
    assert {:error, _} = CheckEvidence.current(context, 3, String.slice(sha, 0, 7), context.evidence)
    assert {:error, _} = CheckEvidence.current(context, 4, sha, context.evidence)
    assert {:error, _} = CheckEvidence.current(%{context | check_attempt: 3}, 3, sha, context.evidence)
    assert {:error, _} = CheckEvidence.current(context, 3, sha, Path.join(context.evidence, "other"))
  end

  test "requires the entire exact check set in its frozen order", %{context: context, sha: sha} do
    complete_set(context)

    for checks <- [[["first"]], [["second"], ["first"]], [["first"], ["second"], ["third"]], [["different"], ["second"]]] do
      altered = put_in(context.settings.checks, checks)
      assert {:error, _} = CheckEvidence.current(altered, 3, sha, context.evidence)
    end

    context = put_in(context.settings.checks, [])
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
  end

  test "incomplete sets and records cannot borrow earlier successful checks", %{context: context, sha: sha} do
    old = complete_set(context)
    record = CheckEvidence.start(context, ["first"], 1, context.evidence)
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    File.write!(record["log_path"], "new first")
    CheckEvidence.finish(record, %{"exit_status" => 0})
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    second = CheckEvidence.start(context, ["second"], 2, context.evidence)
    File.write!(second["log_path"], "unfinished second")
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    assert Enum.all?(old, &File.regular?(&1["log_path"]))
  end

  test "stale attempts, missing completion, bad argv and run identities are rejected", %{context: context, sha: sha} do
    [first, _] = complete_set(context)

    for mutation <- [
          %{"candidate_sha" => String.duplicate("b", 40)},
          %{"attempt" => 1},
          %{"round" => 2},
          %{"completed" => false},
          %{"finished_at" => nil},
          %{"finished_at" => "2000-01-01T00:00:00Z"},
          %{"finished_at" => "invalid"},
          %{"exit_status" => 10},
          %{"error" => "runner failed"},
          %{"argv" => ["different"]},
          %{"run_id" => "stale"},
          %{"record_path" => "other"},
          %{"log_path" => "other"},
          %{"index" => 2}
        ] do
      File.write!(first["record_path"], Jason.encode!(Map.merge(first, mutation)))
      assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence), inspect(mutation)
      assert {:error, :mvp_check_evidence_unavailable} = CheckEvidence.prompt(context, 3, sha, context.evidence)
    end
  end

  test "missing, truncated and digest-mismatched full logs cannot be promoted", %{context: context, sha: sha} do
    [first, _] = complete_set(context, ["original", "second"])

    for bytes <- ["tampered", "orig"] do
      File.write!(first["log_path"], bytes)
      assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    end

    File.rm!(first["log_path"])
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    File.ln_s!(List.last(Receipt.read(context.receipt)["formal_check_evidence"]["records"]), first["log_path"])
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
  end

  test "missing, malformed and non-object record JSON is rejected", %{context: context, sha: sha} do
    [first, _] = complete_set(context)

    for bytes <- ["{", "[]", "null"] do
      File.write!(first["record_path"], bytes)
      assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    end

    File.rm!(first["record_path"])
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
  end

  @tag :check_evidence_boundary
  test "a completed log that becomes unreadable cannot authorize Review or delivery", %{context: context, sha: sha} do
    [record, _] = complete_set(context)
    path = record["log_path"]
    mode = File.stat!(path).mode
    File.chmod!(path, 0o000)

    try do
      assert File.stat!(path).size == record["log_size"]
      assert {:error, :eacces} = File.read(path)
      assert {:error, :mvp_check_evidence_unavailable} = CheckEvidence.current(context, 3, sha, context.evidence)
      assert {:error, :mvp_check_evidence_unavailable} = CheckEvidence.prompt(context, 3, sha, context.evidence)
      assert {:error, :mvp_check_evidence_unavailable} = delivery_proof(context, sha)
    after
      File.chmod!(path, mode)
    end

    assert {:ok, [^record, _]} = CheckEvidence.current(context, 3, sha, context.evidence)
  end

  test "failed and interrupted attempts retain their original artifacts when rerun", %{context: context, sha: sha} do
    failed = CheckEvidence.start(context, ["first"], 1, context.evidence)
    File.write!(failed["log_path"], "failed first attempt")
    failed = CheckEvidence.finish(failed, %{"exit_status" => 10, "repairable" => true})
    failed_json = File.read!(failed["record_path"])
    interrupted = CheckEvidence.start(context, ["first"], 1, context.evidence)
    File.write!(interrupted["log_path"], "partial interrupted output")
    interrupted_json = File.read!(interrupted["record_path"])
    context = %{context | check_attempt: 3}
    [current, _] = complete_set(context, ["current success", "second success"])

    assert {:ok, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    assert current["log_path"] != interrupted["log_path"]
    assert File.read!(failed["log_path"]) == "failed first attempt"
    assert File.read!(failed["record_path"]) == failed_json
    assert File.read!(interrupted["log_path"]) == "partial interrupted output"
    assert File.read!(interrupted["record_path"]) == interrupted_json
    assert {:ok, prompt} = CheckEvidence.prompt(context, 3, sha, context.evidence)
    assert prompt =~ "current success"
    refute prompt =~ "failed first attempt"
    refute prompt =~ "partial interrupted output"
  end

  test "old receipts may run fresh checks without promoting or overwriting old files", %{context: context, sha: sha} do
    old_log = Path.join(context.evidence, "check-1.log")
    old_json = Path.join(context.evidence, "check-1.json")
    File.write!(old_log, "unbound historical success")
    File.write!(old_json, ~s({"exit_status":0}))
    assert {:error, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    complete_set(context)
    assert {:ok, _} = CheckEvidence.current(context, 3, sha, context.evidence)
    assert File.read!(old_log) == "unbound historical success"
    assert File.read!(old_json) == ~s({"exit_status":0})
    assert {:ok, prompt} = CheckEvidence.prompt(context, 3, sha, context.evidence)
    refute prompt =~ "unbound historical success"
  end

  test "expanded argv is bound to the requested evidence and frozen baseline", %{context: context, sha: sha} do
    argv = ["runner", "{workspace}", "{baseline}", "{evidence}"]
    context = put_in(context.settings.checks, [argv])
    expanded = ["runner", context.workspace, Path.join(context.evidence, "baseline"), context.evidence]
    record = CheckEvidence.start(context, expanded, 1, context.evidence)
    File.write!(record["log_path"], "passed")
    CheckEvidence.finish(record, %{"exit_status" => 0})
    assert {:ok, _} = CheckEvidence.current(context, 3, sha, context.evidence)
  end

  test "delivery reconstructs the expected attempt from the saved round instead of the manifest", %{context: context, sha: sha} do
    records = complete_set(context)
    assert {:ok, proof} = delivery_proof(context, sha)
    assert Enum.map(proof, & &1["path"]) == Enum.map(records, & &1["record_path"])

    for record <- records do
      File.write!(record["record_path"], Jason.encode!(Map.put(record, "attempt", 99)))
    end

    data = Receipt.read(context.receipt)
    manifest = Map.put(data["formal_check_evidence"], "attempt", 99)
    Receipt.update(context.receipt, data["status"], %{"formal_check_evidence" => manifest})
    assert {:error, :mvp_check_evidence_unavailable} = delivery_proof(context, sha)

    Receipt.update(context.receipt, data["status"], %{"formal_check_binding" => Map.delete(manifest, "records")})
    assert {:error, :mvp_check_evidence_unavailable} = delivery_proof(context, sha)
  end

  test "a present invalid manifest or a removed manifest with surviving binding never selects legacy", %{context: context, sha: sha} do
    assert {:ok, :legacy} = delivery_proof(context, sha)
    complete_set(context)
    data = Receipt.read(context.receipt)

    for invalid <- [nil, %{}, "invalid"] do
      Receipt.update(context.receipt, data["status"], %{"formal_check_evidence" => invalid})
      assert {:error, :mvp_check_evidence_unavailable} = delivery_proof(context, sha)
    end

    File.write!(context.receipt, Jason.encode!(Map.delete(data, "formal_check_evidence")))
    assert {:error, :mvp_check_evidence_unavailable} = delivery_proof(context, sha)
  end

  defp delivery_proof(context, sha), do: CheckEvidence.delivery_proof(context.receipt, context.workspace, sha)

  defp complete_set(context, outputs \\ ["first passed", "second passed"]) do
    context.settings.checks
    |> Enum.with_index(1)
    |> Enum.map(fn {argv, index} ->
      record = CheckEvidence.start(context, argv, index, context.evidence)
      File.write!(record["log_path"], Enum.at(outputs, index - 1))
      CheckEvidence.finish(record, %{"exit_status" => 0})
    end)
  end
end
