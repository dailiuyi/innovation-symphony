defmodule SymphonyElixir.Mvp.Feedback do
  @moduledoc "At-most-once rejection comments; uncertain writes can only be reconciled by reads."

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Mvp.Receipt

  @spec post(Path.t(), map(), keyword()) :: :ok | {:error, atom()}
  def post(receipt, review, opts) do
    data = Receipt.read(receipt)
    round = List.last(data["rounds"])

    if Map.has_key?(round, "comment") do
      {:error, :mvp_comment_already_attempted}
    else
      intent = %{
        "round" => round["round"],
        "candidate_sha" => round["candidate_sha"],
        "body" => body(round, review),
        "id" => nil
      }

      Receipt.update_round(receipt, "comment_pending", %{"comment" => intent})

      case Client.request("POST", path(data), %{}, %{"body" => intent["body"]}, opts) do
        {:ok, %{status: 201, body: comment}} -> confirm(receipt, intent, comment)
        _ -> {:error, :mvp_comment_uncertain}
      end
    end
  end

  @spec reconcile(Path.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def reconcile(receipt, opts) do
    data = Receipt.read(receipt)
    intent = (List.last(data["rounds"]) || %{}) |> Map.get("comment")

    with true <- is_map(intent),
         {:ok, comments} <- comments(path(data), 1, opts, []),
         [comment] <- Enum.filter(comments, &matches?(&1, intent)),
         :ok <- confirm(receipt, intent, comment) do
      {:ok, "Issue comment #{comment["id"]}; execution remains blocked"}
    else
      _ -> {:error, :mvp_no_unique_matching_comment}
    end
  end

  defp comments(path, page, opts, acc) do
    case Client.request("GET", path, %{"per_page" => 100, "page" => page}, nil, opts) do
      {:ok, %{status: 200, body: values}} when is_list(values) ->
        if length(values) == 100, do: comments(path, page + 1, opts, acc ++ values), else: {:ok, acc ++ values}

      _ ->
        {:error, :mvp_comment_lookup_failed}
    end
  end

  defp confirm(receipt, intent, comment) do
    if matches?(comment, intent) do
      Receipt.update_round(receipt, "blocked", %{"comment" => Map.put(intent, "id", comment["id"])})
    else
      {:error, :mvp_comment_uncertain}
    end
  end

  defp matches?(%{"id" => id, "body" => body}, intent),
    do: is_integer(id) and id > 0 and body == intent["body"] and (is_nil(intent["id"]) or intent["id"] == id)

  defp matches?(_, _), do: false

  defp path(data), do: "/repos/#{data["repository"]}/issues/#{data["issue"]}/comments"

  defp body(round, review) do
    # Render all model text literally, and remove ASCII @ even inside escaped HTML.
    reason = review |> Jason.encode!(pretty: true) |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("@", "＠")
    marker = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    "<!-- symphony-review:#{marker} -->\nReview rejected · round #{round["round"]}\nCandidate: #{round["candidate_sha"]}\n\n<pre>#{reason}</pre>"
  end
end
