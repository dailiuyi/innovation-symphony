defmodule SymphonyElixir.Mvp.Usage do
  @moduledoc "Observed per-session token totals; absent measurements and prices remain unknown."

  alias SymphonyElixir.Mvp.Receipt

  @fields [{"input_tokens", "inputTokens"}, {"output_tokens", "outputTokens"}, {"total_tokens", "totalTokens"}]

  @spec empty() :: map()
  def empty, do: %{"input_tokens" => nil, "output_tokens" => nil, "total_tokens" => nil, "cost" => nil}

  @spec record(Path.t(), String.t(), map()) :: :ok
  def record(receipt, role, message) do
    data = Receipt.read(receipt)
    rounds = data["rounds"]
    round = List.last(rounds)
    previous = round["usage"][role]
    observed = extract(message)

    usage = Map.new(@fields, fn {key, _} -> {key, maximum(previous[key], observed[key])} end) |> Map.put("cost", nil)
    updated = List.replace_at(rounds, -1, put_in(round, ["usage", role], usage))
    Receipt.update(receipt, data["status"], %{"rounds" => updated, "usage" => aggregate(updated)})
  end

  @spec aggregate([map()]) :: map()
  def aggregate(rounds) do
    sessions = Enum.flat_map(rounds, &Map.values(&1["usage"]))
    Map.new(@fields, fn {key, _} -> {key, total(sessions, key)} end) |> Map.put("cost", nil)
  end

  defp extract(message) do
    # AppServer forwards protocol notifications as payload, and some completions carry usage directly.
    normalized = normalize(message)
    payload = if is_map(normalized["payload"]), do: normalized["payload"], else: normalized

    sources = [
      at(payload, ["params", "tokenUsage", "total"]),
      at(payload, ["params", "msg", "payload", "info", "total_token_usage"]),
      at(payload, ["params", "msg", "info", "total_token_usage"]),
      at(payload, ["tokenUsage", "total"]),
      at(payload, ["params", "usage"]),
      payload["usage"],
      normalized["usage"]
    ]

    source = Enum.find(sources, %{}, &is_map/1)

    Map.new(@fields, fn {key, camel} ->
      value = source[key] || source[camel]
      {key, if(is_integer(value) and value >= 0, do: value)}
    end)
  end

  defp normalize(value) when is_map(value), do: Map.new(Map.to_list(value), fn {key, item} -> {to_string(key), normalize(item)} end)
  defp normalize(value), do: value

  defp at(value, []), do: value
  defp at(value, [key | rest]) when is_map(value), do: at(value[key], rest)
  defp at(_, _), do: nil

  defp maximum(nil, value), do: value
  defp maximum(value, nil), do: value
  defp maximum(left, right), do: max(left, right)

  defp total(sessions, key) do
    values = Enum.map(sessions, & &1[key])
    known = Enum.reject(values, &is_nil/1)
    %{"observed" => if(known != [], do: Enum.sum(known)), "complete" => length(known) == length(values)}
  end
end
