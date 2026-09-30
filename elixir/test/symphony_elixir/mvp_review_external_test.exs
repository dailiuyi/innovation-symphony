defmodule SymphonyElixir.Mvp.ReviewExternalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.Review

  test "legacy reviews and old rework payloads conservatively route rejection to code repair" do
    assert {:ok, legacy_rejection} = Review.parse(~s({"approved":false,"summary":"Needs a fix"}), 0)
    assert Review.disposition(legacy_rejection) == :repair_code
    assert Review.external_conditions(legacy_rejection) == []
    assert {:ok, %{"approved" => true} = legacy_approval} = Review.parse(~s({"approved":true,"summary":" "}), 0)
    assert Review.disposition(legacy_approval) == :approved

    old_rework = %{"approved" => false, "summary" => "Add a missing assertion", "criteria" => [criterion("A1", false)]}
    assert {:ok, ^old_rework} = Review.parse(Jason.encode!(old_rework), 1)
    assert Review.disposition(old_rework) == :repair_code
    assert Review.external_conditions(old_rework) == []
  end

  test "rework schema requires strict blockers while preserving legacy parse compatibility" do
    schema = Review.schema(2)
    assert schema["additionalProperties"] == false
    assert "blockers" in schema["required"]
    assert schema["properties"]["blockers"]["type"] == "array"
    assert schema["properties"]["blockers"]["items"]["additionalProperties"] == false

    assert Enum.sort(schema["properties"]["blockers"]["items"]["required"]) ==
             ["acceptance", "handoff", "kind", "reason", "required_evidence"]

    assert schema["properties"]["blockers"]["items"]["properties"]["kind"]["enum"] ==
             ["code_defect", "external_condition"]

    assert Review.schema(0)["properties"] == %{"approved" => %{"type" => "boolean"}, "summary" => %{"type" => "string"}}
  end

  test "external-only blockers wait and are returned without relying on summary wording" do
    review = review([criterion("A1", false)], [blocker("A1", "external_condition")])
    assert {:ok, ^review} = Review.parse(Jason.encode!(review), 1)
    assert Review.disposition(review) == :awaiting_external
    assert Review.external_conditions(review) == review["blockers"]
    assert Review.valid_external_conditions?(review["blockers"])

    assert Review.disposition(%{"approved" => false, "summary" => "blocked by credentials", "criteria" => [], "blockers" => []}) ==
             :repair_code
  end

  test "mixed classification and code defects remain repair work" do
    code = blocker("A1", "code_defect", %{"required_evidence" => "", "handoff" => "Fix the assertion"})
    external = blocker("A2", "external_condition")
    review = review([criterion("A1", false), criterion("A2", false)], [code, external])

    assert {:ok, ^review} = Review.parse(Jason.encode!(review), 2)
    assert Review.disposition(review) == :repair_code
    assert Review.external_conditions(review) == [external]
    refute Review.valid_external_conditions?(review["blockers"])
  end

  test "provided classification must cover every inadequate criterion and reference no adequate criterion" do
    incomplete = review([criterion("A1", false), criterion("A2", false)], [blocker("A1", "code_defect")])
    wrong_criterion = review([criterion("A1", false), criterion("A2", true)], [blocker("A2", "code_defect")])
    empty_for_rejection = review([criterion("A1", false)], [])

    for invalid <- [incomplete, wrong_criterion, empty_for_rejection] do
      assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(invalid), 2)
    end

    empty_without_inadequate = review([criterion("A1", true)], [])
    assert {:ok, ^empty_without_inadequate} = Review.parse(Jason.encode!(empty_without_inadequate), 2)
    assert Review.disposition(empty_without_inadequate) == :repair_code
  end

  test "approved reviews cannot contain blockers" do
    contradictory = review([criterion("A1", true)], [blocker("A1", "external_condition")], true)
    assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(contradictory), 2)
    assert Review.disposition(contradictory) == :repair_code
  end

  test "blockers reject unknown keys, malformed strings, invalid kinds, and empty external handoffs" do
    valid = blocker("A1", "external_condition")

    invalid_blockers = [
      nil,
      %{},
      "external_condition",
      [Map.put(valid, "extra", true)],
      [Map.delete(valid, "required_evidence")],
      [%{valid | "kind" => "environment"}],
      [%{valid | "required_evidence" => "  "}],
      [%{valid | "handoff" => ""}],
      [%{valid | "reason" => "\t"}],
      [%{valid | "acceptance" => " A1 "}]
    ]

    for blockers <- invalid_blockers do
      malformed = review([criterion("A1", false)], blockers)
      assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(malformed), 1)
    end

    malformed_outer = Map.put(review([criterion("A1", false)], [valid]), "unexpected", true)
    assert {:error, :mvp_invalid_review} = Review.parse(Jason.encode!(malformed_outer), 1)
  end

  test "only non-empty external blocker lists satisfy the shared recovery validator" do
    external = blocker("A1", "external_condition")
    refute Review.valid_external_conditions?([])
    refute Review.valid_external_conditions?([blocker("A1", "code_defect")])
    refute Review.valid_external_conditions?([Map.put(external, "unknown", 1)])
    assert Review.valid_external_conditions?([external])
  end

  defp review(criteria, blockers, approved \\ false) do
    %{"approved" => approved, "summary" => "Review result", "criteria" => criteria, "blockers" => blockers}
  end

  defp criterion(acceptance, adequate?) do
    %{
      "acceptance" => acceptance,
      "tests" => if(adequate?, do: ["test/mvp_test.exs: acceptance case"], else: []),
      "assertion_strength" => "Checks the result directly",
      "failure_sensitivity" => "Removing the behavior fails this assertion",
      "adequate" => adequate?
    }
  end

  defp blocker(acceptance, kind, overrides \\ %{}) do
    Map.merge(
      %{
        "acceptance" => acceptance,
        "kind" => kind,
        "reason" => "A stated condition prevents acceptance",
        "required_evidence" => "Show the external result",
        "handoff" => "Provide evidence for the reviewer"
      },
      overrides
    )
  end
end
