defmodule SymphonyElixir.Mvp.Feedback do
  @moduledoc "At-most-once rejection comments; uncertain writes can only be reconciled by reads."

  alias SymphonyElixir.Mvp.Forge
  alias SymphonyElixir.Mvp.Receipt

  @spec post(Path.t(), map(), keyword()) :: :ok | {:error, atom()}
  def post(receipt, review, opts) do
    data = Receipt.read(receipt)
    round = List.last(data["rounds"])
    external_id = Keyword.get(opts, :external_review_id)

    if Forge.receipt_scope(data, opts) != :ok or already_attempted?(data, round, external_id) do
      {:error, :mvp_comment_already_attempted}
    else
      intent = %{
        "round" => round["round"],
        "candidate_sha" => round["candidate_sha"],
        "body" => body(round, review),
        "id" => nil
      }

      intent = external_intent(intent, round, external_id)

      save_intent(receipt, "comment_pending", intent)

      case Forge.comments("POST", data["repository"], data["issue"], %{}, %{"body" => intent["body"]}, opts) do
        {:ok, %{status: 201, body: comment}} -> confirm(receipt, intent, comment)
        _ -> {:error, :mvp_comment_uncertain}
      end
    end
  end

  @spec reconcile(Path.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def reconcile(receipt, opts) do
    data = Receipt.read(receipt)
    intent = pending_intent(data)

    with :ok <- Forge.receipt_scope(data, opts),
         true <- is_map(intent),
         {:ok, comments} <- comments(data, 1, opts, []),
         [comment] <- Enum.filter(comments, &matches?(&1, intent)),
         :ok <- confirm(receipt, intent, comment) do
      {:ok, "Issue comment #{comment["id"]}; execution remains blocked"}
    else
      _ -> {:error, :mvp_no_unique_matching_comment}
    end
  end

  defp comments(data, page, opts, acc) do
    case Forge.comments("GET", data["repository"], data["issue"], %{"per_page" => 100, "page" => page}, nil, opts) do
      {:ok, %{status: 200, body: values}} when is_list(values) ->
        if length(values) == 100, do: comments(data, page + 1, opts, acc ++ values), else: {:ok, acc ++ values}

      _ ->
        {:error, :mvp_comment_lookup_failed}
    end
  end

  defp confirm(receipt, intent, comment) do
    if matches?(comment, intent) do
      save_intent(receipt, "blocked", Map.put(intent, "id", comment["id"]))
    else
      {:error, :mvp_comment_uncertain}
    end
  end

  defp already_attempted?(data, _round, external_id) when is_binary(external_id),
    do: Map.has_key?(data["external_feedback"] || %{}, external_id)

  defp already_attempted?(_data, round, _external_id), do: Map.has_key?(round, "comment")

  defp save_intent(receipt, status, %{"external_review_id" => external_id} = intent) do
    data = Receipt.read(receipt)
    feedback = Map.put(data["external_feedback"] || %{}, external_id, intent)
    pending = if is_nil(intent["id"]), do: external_id, else: nil
    rounds = List.update_at(data["rounds"], -1, &Map.put(&1, "comment", intent))
    Receipt.update(receipt, status, %{"external_feedback" => feedback, "pending_external_feedback" => pending, "rounds" => rounds})
  end

  defp save_intent(receipt, status, intent), do: Receipt.update_round(receipt, status, %{"comment" => intent})

  defp pending_intent(%{"pending_external_feedback" => external_id} = data) when is_binary(external_id),
    do: (data["external_feedback"] || %{})[external_id]

  defp pending_intent(data), do: (List.last(data["rounds"]) || %{})["comment"]

  defp external_intent(intent, round, external_id) when is_binary(external_id),
    do: Map.merge(intent, %{"external_review_id" => external_id, "prior_comment" => round["comment"]})

  defp external_intent(intent, _round, _external_id), do: intent

  defp matches?(%{"id" => id, "body" => body}, intent),
    do: is_integer(id) and id > 0 and body == intent["body"] and (is_nil(intent["id"]) or intent["id"] == id)

  defp matches?(_, _), do: false

  defp body(round, review) do
    # Render all model text literally, and remove ASCII @ even inside escaped HTML.
    reason = review |> Jason.encode!(pretty: true) |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("@", "＠")
    marker = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    "<!-- symphony-review:#{marker} -->\nReview rejected · round #{round["round"]}\nCandidate: #{round["candidate_sha"]}\n\n<pre>#{reason}</pre>"
  end
end
