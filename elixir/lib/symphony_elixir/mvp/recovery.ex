defmodule SymphonyElixir.Mvp.Recovery do
  @moduledoc "Opt-in recovery budgets and diagnostic advice; diagnosis never grants acceptance or permissions."

  # stage_attempts includes the initial stage call. These limits are engineering defaults.
  @defaults %{
    enabled: false,
    max_rework: 20,
    diagnose_every: 3,
    stage_attempts: 3,
    max_elapsed_ms: 7_200_000,
    max_agent_attempts: 64
  }
  @keys Enum.map(Map.keys(@defaults), &Atom.to_string/1)
  @actions ~w(repair_code retry_stage stop)
  @nonempty_string %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action", "summary", "steps"],
    "properties" => %{
      "action" => %{"type" => "string", "enum" => @actions},
      "summary" => @nonempty_string,
      "steps" => %{"type" => "array", "minItems" => 1, "items" => @nonempty_string}
    }
  }

  @spec settings(term()) :: {:ok, map()} | {:error, :invalid_mvp_recovery}
  def settings(nil), do: {:ok, @defaults}

  def settings(raw) when is_map(raw) do
    policy = Map.new(@defaults, fn {key, default} -> {key, Map.get(raw, Atom.to_string(key), default)} end)

    if Map.keys(raw) -- @keys == [] and is_boolean(policy.enabled) and
         integer_in?(policy.max_rework, 1..100) and integer_in?(policy.diagnose_every, 1..10) and
         integer_in?(policy.stage_attempts, 1..5) and integer_in?(policy.max_elapsed_ms, 1..86_400_000) and
         integer_in?(policy.max_agent_attempts, 1..500) do
      {:ok, policy}
    else
      {:error, :invalid_mvp_recovery}
    end
  end

  def settings(_), do: {:error, :invalid_mvp_recovery}

  @spec enabled?(map()) :: boolean()
  def enabled?(%{recovery: %{enabled: true}}), do: true
  def enabled?(_), do: false

  @spec limit(map()) :: non_neg_integer()
  def limit(settings) do
    if enabled?(settings), do: settings.recovery.max_rework, else: Map.get(settings, :max_rework) || 0
  end

  @spec diagnose?(map(), pos_integer(), map(), [String.t()]) :: boolean()
  def diagnose?(policy, number, feedback, history) do
    fingerprint = fingerprint(feedback)

    (feedback["kind"] == "check" and feedback["repairable"] == false) or
      rem(number, policy.diagnose_every) == 0 or Enum.count(history, &(&1 == fingerprint)) >= 2
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(feedback) do
    feedback
    |> failure_identity()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec schema() :: map()
  def schema, do: @schema

  @spec parse(term()) :: {:ok, map()} | {:error, :mvp_invalid_diagnosis}
  def parse(text) when is_binary(text) do
    with {:ok, value} <- Jason.decode(text),
         true <- valid_diagnosis?(value) do
      {:ok, value}
    else
      _ -> {:error, :mvp_invalid_diagnosis}
    end
  end

  def parse(_), do: {:error, :mvp_invalid_diagnosis}

  @spec within_budget?(map(), term(), integer()) :: boolean()
  def within_budget?(policy, started_at_iso, now_unix_ms) when is_binary(started_at_iso) and is_integer(now_unix_ms) do
    case DateTime.from_iso8601(started_at_iso) do
      {:ok, started_at, _offset} ->
        elapsed = now_unix_ms - DateTime.to_unix(started_at, :millisecond)
        elapsed >= 0 and elapsed < policy.max_elapsed_ms

      _ ->
        false
    end
  end

  def within_budget?(_policy, _started_at_iso, _now_unix_ms), do: false

  defp integer_in?(value, range), do: is_integer(value) and value in range

  defp failure_identity(%{"kind" => "check"} = feedback),
    do: {:check, feedback["index"], feedback["exit_status"]}

  defp failure_identity(feedback), do: {:review, feedback["summary"], feedback["criteria"]}

  defp valid_diagnosis?(%{"action" => action, "summary" => summary, "steps" => steps} = value) do
    map_size(value) == 3 and action in @actions and nonempty?(summary) and
      is_list(steps) and steps != [] and Enum.all?(steps, &nonempty?/1)
  end

  defp valid_diagnosis?(_), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
