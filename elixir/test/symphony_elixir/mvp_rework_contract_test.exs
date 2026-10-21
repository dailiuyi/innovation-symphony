defmodule SymphonyElixir.Mvp.ReworkContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mvp.{Delivery, Feedback, Receipt, Review, Usage}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-rework-contract-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, receipt} = Receipt.claim(%{state_dir: root}, %{id: "42", native_ref: %{"repo" => "owner/repo"}})
    round = %{"round" => 1, "candidate_sha" => String.duplicate("a", 40), "usage" => %{"coder" => Usage.empty(), "reviewer" => Usage.empty()}}
    Receipt.update(receipt, "reviewing", %{"rounds" => [round]})
    %{receipt: receipt}
  end

  test "A6 read-only reconciliation paginates and records exactly one matching comment without resuming", %{receipt: receipt} do
    intent = uncertain_comment(receipt)

    request = fn "GET", "/repos/owner/repo/issues/42/comments", params, nil, _ ->
      assert params["per_page"] == 100

      case params["page"] do
        1 -> {:ok, %{status: 200, body: List.duplicate(%{"id" => 1, "body" => "other"}, 100)}}
        2 -> {:ok, %{status: 200, body: [%{"id" => 99, "body" => intent["body"]}]}}
      end
    end

    assert {:ok, message} = Delivery.reconcile(receipt, opts(request))
    assert message =~ "execution remains blocked"
    data = Receipt.read(receipt)
    assert data["status"] == "blocked"
    assert hd(data["rounds"])["comment"]["id"] == 99
    assert {:ok, _} = Feedback.reconcile(receipt, opts(request))
    assert {:error, :mvp_comment_already_attempted} = Feedback.post(receipt, %{}, opts(request))
  end

  test "A6 reconciliation never guesses on absence, duplicates, malformed responses or read errors", %{receipt: receipt} do
    intent = uncertain_comment(receipt)
    match = %{"id" => 99, "body" => intent["body"]}

    for response <- [
          {:ok, %{status: 200, body: []}},
          {:ok, %{status: 200, body: [match, match]}},
          {:ok, %{status: 200, body: [%{}, %{"id" => 0, "body" => intent["body"]}]}},
          {:ok, %{status: 200, body: %{}}},
          {:error, :timeout}
        ] do
      before = Receipt.read(receipt)
      request = fn "GET", _, _, nil, _ -> response end
      assert {:error, :mvp_no_unique_matching_comment} = Delivery.reconcile(receipt, opts(request))
      assert Receipt.read(receipt) == before
    end

    Receipt.update_round(receipt, "blocked", %{"comment" => Map.put(intent, "id", 100)})
    request = fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: [match]}} end
    assert {:error, :mvp_no_unique_matching_comment} = Feedback.reconcile(receipt, opts(request))
  end

  test "A6 reconciliation with no comment intent issues no requests", %{receipt: receipt} do
    Receipt.update(receipt, "blocked")
    assert {:error, :mvp_no_unique_matching_comment} = Delivery.reconcile(receipt, [])
    Receipt.update(receipt, "blocked", %{"rounds" => []})
    assert {:error, :mvp_no_unique_matching_comment} = Feedback.reconcile(receipt, [])
  end

  test "A8 review rejects malformed or contradictory test assessments and accepts explicit test rejection" do
    criterion = %{
      "acceptance" => "A8",
      "tests" => ["test/file.exs: test name"],
      "assertion_strength" => "Exact rejection is asserted",
      "failure_sensitivity" => "Removing validation makes the assertion fail",
      "adequate" => true
    }

    valid = %{"approved" => true, "summary" => "Reviewed", "criteria" => [criterion]}
    assert {:ok, ^valid} = Review.parse(Jason.encode!(valid), 2)
    assert {:ok, %{"approved" => false}} = Review.parse(Jason.encode!(%{valid | "approved" => false, "criteria" => [%{criterion | "tests" => [], "adequate" => false}]}), 1)

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(valid, "summary", " "),
          Map.put(valid, "approved", "false"),
          Map.delete(valid, "criteria"),
          Map.put(valid, "extra", 1),
          Map.put(valid, "criteria", []),
          Map.put(valid, "criteria", "tests passed"),
          Map.put(valid, "criteria", [%{}]),
          Map.put(valid, "criteria", [%{criterion | "tests" => []}]),
          Map.put(valid, "criteria", [%{criterion | "adequate" => false}]),
          Map.put(valid, "criteria", [%{criterion | "tests" => [""]}]),
          Map.put(valid, "criteria", [%{criterion | "failure_sensitivity" => ""}])
        ] do
      assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(invalid), 2)
    end

    assert {:error, :mvp_invalid_review} = Review.parse("not json", 2)
    assert {:ok, ^valid} = Review.parse(Jason.encode!(valid), 0)
    assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(Map.put(valid, "criteria", [123])), 0)
    assert {:ok, %{"approved" => false}} = Review.parse(~s({"approved":false,"summary":"Rejected"}), 0)
    assert {:ok, %{"approved" => true}} = Review.parse(~s({"approved":true,"summary":" "}), 0)

    assert Review.schema(2)["properties"]["criteria"]["items"]["required"] ==
             ["acceptance", "tests", "assertion_strength", "failure_sensitivity", "adequate"]
  end

  test "A9 cumulative notifications are not double counted and missing or partial measurements remain unknown", %{receipt: receipt} do
    for event <- [
          %{payload: "bad json", detail: self(), timestamp: DateTime.utc_now()},
          %{payload: %{params: "bad params"}},
          %{usage: %{input_tokens: -1, output_tokens: "7", total_tokens: nil}}
        ] do
      assert :ok = Usage.record(receipt, "coder", event)
    end

    assert hd(Receipt.read(receipt)["rounds"])["usage"]["coder"] == Usage.empty()
    assert Receipt.read(receipt)["usage"]["total_tokens"] == %{"observed" => nil, "complete" => false}

    Usage.record(receipt, "coder", %{payload: %{params: %{tokenUsage: %{total: %{inputTokens: 10, totalTokens: 12}}}}})
    Usage.record(receipt, "coder", %{usage: %{input_tokens: 8, output_tokens: 2, total_tokens: 12}})
    Usage.record(receipt, "coder", %{event: :turn_completed})
    Usage.record(receipt, "reviewer", %{payload: %{params: %{usage: %{input_tokens: 3, output_tokens: 0, total_tokens: 3}}}})
    assert hd(Receipt.read(receipt)["rounds"])["usage"]["coder"] == %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12, "cost" => nil}
    assert Receipt.read(receipt)["usage"]["total_tokens"] == %{"observed" => 15, "complete" => true}
    assert Receipt.read(receipt)["usage"]["output_tokens"] == %{"observed" => 2, "complete" => true}
    assert Receipt.read(receipt)["usage"]["cost"] == nil
  end

  defp uncertain_comment(receipt) do
    assert {:error, :mvp_comment_uncertain} = Feedback.post(receipt, %{"approved" => false, "summary" => "reason"}, opts(fn "POST", _, _, _, _ -> {:error, :timeout} end))
    hd(Receipt.read(receipt)["rounds"])["comment"]
  end

  defp opts(request) do
    [tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "fake-token"}}, request_fun: request]
  end
end
