defmodule SymphonyElixir.Mvp.ExternalFeedbackTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.{Feedback, Receipt}

  setup do
    root = Path.join(System.tmp_dir!(), "external-feedback-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")
    original = %{"id" => 10, "body" => "Original rejection"}
    data = %{"status" => "awaiting_external", "repository" => "owner/repo", "issue" => "42", "rounds" => [%{"round" => 1, "candidate_sha" => String.duplicate("a", 40), "comment" => original}]}
    File.write!(receipt, Jason.encode!(data))
    %{receipt: receipt, original: original}
  end

  test "each external review has its own confirmed comment and cannot overwrite or repeat the original", %{receipt: receipt, original: original} do
    request = fn "POST", _, _, body, _ -> {:ok, %{status: 201, body: %{"id" => 11, "body" => body["body"]}}} end
    opts = options(request)
    assert :ok = Feedback.post(receipt, %{"approved" => false, "summary" => "A new code defect"}, opts)
    data = Receipt.read(receipt)
    assert data["external_feedback"]["external-op-1"]["prior_comment"] == original
    assert hd(data["rounds"])["comment"] == data["external_feedback"]["external-op-1"]
    assert data["external_feedback"]["external-op-1"]["id"] == 11
    assert data["external_feedback"]["external-op-1"]["candidate_sha"] == String.duplicate("a", 40)
    assert data["pending_external_feedback"] == nil
    assert data["status"] == "blocked"
    assert {:error, :mvp_comment_already_attempted} = Feedback.post(receipt, %{"approved" => false}, opts)
  end

  test "uncertain external feedback is reconciled by reads in its own slot", %{receipt: receipt, original: original} do
    request = fn "POST", _, _, _, _ -> {:error, :network_timeout} end
    assert {:error, :mvp_comment_uncertain} = Feedback.post(receipt, %{"approved" => false, "summary" => "Still missing proof"}, options(request))
    pending = Receipt.read(receipt)
    assert pending["status"] == "comment_pending"
    assert pending["pending_external_feedback"] == "external-op-1"
    intent = pending["external_feedback"]["external-op-1"]
    lookup = fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: [%{"id" => 12, "body" => intent["body"]}]}} end
    assert {:ok, _} = Feedback.reconcile(receipt, options(lookup))
    confirmed = Receipt.read(receipt)
    assert confirmed["external_feedback"]["external-op-1"]["prior_comment"] == original
    assert hd(confirmed["rounds"])["comment"] == confirmed["external_feedback"]["external-op-1"]
    assert confirmed["external_feedback"]["external-op-1"]["id"] == 12
    assert confirmed["pending_external_feedback"] == nil
  end

  defp options(request) do
    [external_review_id: "external-op-1", request_fun: request, tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "test-token"}}]
  end
end
