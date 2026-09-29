defmodule SymphonyElixir.Mvp.RecoveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.Recovery

  test "absent recovery is opt-in and legacy rework limits remain unchanged" do
    assert {:ok, defaults} = Recovery.settings(nil)

    assert defaults == %{
             enabled: false,
             max_rework: 20,
             diagnose_every: 3,
             stage_attempts: 3,
             max_elapsed_ms: 7_200_000,
             max_agent_attempts: 64
           }

    assert {:ok, ^defaults} = Recovery.settings(%{})
    refute Recovery.enabled?(%{})
    refute Recovery.enabled?(%{recovery: nil})
    refute Recovery.enabled?(%{recovery: defaults})
    refute Recovery.enabled?(%{recovery: %{enabled: "true"}})
    assert Recovery.limit(%{}) == 0
    assert Recovery.limit(%{max_rework: nil}) == 0
    assert Recovery.limit(%{max_rework: 5, recovery: defaults}) == 5
  end

  test "enabled recovery uses its own total budget and accepts the configured boundaries" do
    assert {:ok, policy} = Recovery.settings(%{"enabled" => true})
    assert Recovery.enabled?(%{recovery: policy})
    assert Recovery.limit(%{recovery: policy, max_rework: 5}) == 20

    for {key, minimum, maximum} <- bounds(), value <- [minimum, maximum] do
      assert {:ok, policy} = Recovery.settings(%{"enabled" => true, key => value})
      assert policy[String.to_existing_atom(key)] == value
    end
  end

  test "configuration rejects unknown fields, wrong types and invalid limits even when disabled" do
    for raw <- [false, true, 1, [], "enabled", %{"unknown" => 1}, %{enabled: true}, %{"enabled" => nil}, %{"enabled" => "true"}] do
      assert {:error, :invalid_mvp_recovery} = Recovery.settings(raw)
    end

    for {key, minimum, maximum} <- bounds(), value <- [minimum - 1, maximum + 1, 1.0, "3", nil, true] do
      assert {:error, :invalid_mvp_recovery} = Recovery.settings(%{"enabled" => false, key => value})
    end
  end

  test "diagnosis escalates on cadence, a third identical failure, or an unknown check" do
    {:ok, policy} = Recovery.settings(%{"enabled" => true})
    failure = check()
    fingerprint = Recovery.fingerprint(failure)

    refute Recovery.diagnose?(policy, 1, failure, [])
    refute Recovery.diagnose?(policy, 2, failure, [fingerprint, "different"])
    assert Recovery.diagnose?(policy, 3, failure, [])
    assert Recovery.diagnose?(policy, 6, failure, [])
    assert Recovery.diagnose?(policy, 4, failure, [fingerprint, "different", fingerprint])
    assert Recovery.diagnose?(policy, 1, Map.put(failure, "repairable", false), [])
    refute Recovery.diagnose?(policy, 1, %{"summary" => "review", "repairable" => false}, [])
    refute Recovery.diagnose?(policy, 1, Map.delete(failure, "repairable"), [])
    assert Recovery.diagnose?(%{policy | diagnose_every: 1}, 1, failure, [])
  end

  test "check fingerprints use check identity and ignore changing paths, commands and diagnostics" do
    failure = check()
    fingerprint = Recovery.fingerprint(failure)
    assert fingerprint =~ ~r/^[0-9a-f]{64}$/

    updated = Map.merge(failure, %{"argv" => ["other"], "log_path" => "/round-2/log", "operator_diagnostic" => "new", "repairable" => false})
    assert Recovery.fingerprint(updated) == fingerprint
    refute Recovery.fingerprint(Map.put(failure, "index", 2)) == fingerprint
    refute Recovery.fingerprint(Map.put(failure, "exit_status", 1)) == fingerprint
  end

  test "review fingerprints retain summary and criteria, independently of map key order" do
    criterion = %{"acceptance" => "handles failures", "adequate" => false, "tests" => ["a", "b"]}
    feedback = %{"summary" => "missing assertion", "criteria" => [criterion]}
    reordered = %{"criteria" => [Map.new(Enum.reverse(Map.to_list(criterion)))], "summary" => "missing assertion", "approved" => false}
    fingerprint = Recovery.fingerprint(feedback)
    assert Recovery.fingerprint(reordered) == fingerprint
    refute Recovery.fingerprint(Map.put(feedback, "summary", "another defect")) == fingerprint
    refute Recovery.fingerprint(put_in(feedback, ["criteria"], [%{criterion | "tests" => ["b"]}])) == fingerprint
    refute Recovery.fingerprint(check()) == fingerprint
  end

  test "diagnosis schema exposes only advice actions and rejects extra authority" do
    schema = Recovery.schema()
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false
    assert Enum.sort(schema["required"]) == ["action", "steps", "summary"]
    assert Enum.sort(Map.keys(schema["properties"])) == ["action", "steps", "summary"]
    assert schema["properties"]["action"]["enum"] == ["repair_code", "retry_stage", "stop"]
    assert schema["properties"]["summary"]["pattern"] == "\\S"
    assert schema["properties"]["steps"]["minItems"] == 1

    for action <- schema["properties"]["action"]["enum"] do
      value = diagnosis(action)
      assert {:ok, ^value} = Recovery.parse(" \n" <> Jason.encode!(value) <> "\n ")
    end
  end

  test "diagnosis requires one complete JSON object with nonempty summary and steps" do
    valid = diagnosis("repair_code")

    invalid_values = [
      [],
      nil,
      true,
      "text",
      %{},
      Map.delete(valid, "steps"),
      Map.put(valid, "approved", true),
      Map.put(valid, "action", "approve"),
      Map.put(valid, "action", false),
      Map.put(valid, "summary", ""),
      Map.put(valid, "summary", " \n\t"),
      Map.put(valid, "summary", 1),
      Map.put(valid, "steps", []),
      Map.put(valid, "steps", "fix"),
      Map.put(valid, "steps", ["fix", " "]),
      Map.put(valid, "steps", [1])
    ]

    for value <- invalid_values do
      assert {:error, :mvp_invalid_diagnosis} = Recovery.parse(Jason.encode!(value))
    end

    json = Jason.encode!(valid)

    for text <- [nil, 1, [], "", "broken", "```json\n#{json}\n```", "Diagnosis: #{json}", json <> json, json <> " done"] do
      assert {:error, :mvp_invalid_diagnosis} = Recovery.parse(text)
    end
  end

  test "elapsed budget is inclusive at start, exclusive at deadline, and rejects clock reversal" do
    policy = %{max_elapsed_ms: 1_000}
    start = "2026-09-29T00:00:00.123Z"
    {:ok, timestamp, 0} = DateTime.from_iso8601(start)
    now = DateTime.to_unix(timestamp, :millisecond)
    assert Recovery.within_budget?(policy, start, now)
    assert Recovery.within_budget?(policy, start, now + 999)
    refute Recovery.within_budget?(policy, start, now + 1_000)
    refute Recovery.within_budget?(policy, start, now + 1_001)
    refute Recovery.within_budget?(policy, start, now - 1)
    assert Recovery.within_budget?(policy, "2026-09-29T08:00:00.123+08:00", now)

    for invalid <- [nil, 1, "", "2026-09-29", "2026-02-30T00:00:00Z", "2026-09-29T00:00:00"] do
      refute Recovery.within_budget?(policy, invalid, now)
    end

    refute Recovery.within_budget?(policy, start, "now")
  end

  defp bounds, do: [{"max_rework", 1, 100}, {"diagnose_every", 1, 10}, {"stage_attempts", 1, 5}, {"max_elapsed_ms", 1, 86_400_000}, {"max_agent_attempts", 1, 500}]

  defp check, do: %{"kind" => "check", "index" => 1, "exit_status" => 10, "repairable" => true, "argv" => ["mix", "test"], "log_path" => "/round-1/log"}
  defp diagnosis(action), do: %{"action" => action, "summary" => "Investigate repeated failure", "steps" => ["Read the complete check log"]}
end
