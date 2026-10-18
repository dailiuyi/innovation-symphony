defmodule SymphonyElixir.Mvp.Review do
  @moduledoc "Structured review contract, including acceptance-to-test evidence in rework mode."

  alias SymphonyElixir.Mvp.StructuredOutput

  @legacy %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["approved", "summary"],
    "properties" => %{"approved" => %{"type" => "boolean"}, "summary" => %{"type" => "string"}}
  }
  @criterion %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["acceptance", "tests", "assertion_strength", "failure_sensitivity", "adequate"],
    "properties" => %{
      "acceptance" => %{"type" => "string", "description" => "Full acceptance ID and behavior. Every related blocker must copy this exact string verbatim."},
      "tests" => %{"type" => "array", "items" => %{"type" => "string"}},
      "assertion_strength" => %{"type" => "string"},
      "failure_sensitivity" => %{"type" => "string"},
      "adequate" => %{"type" => "boolean"}
    }
  }
  @nonempty_string %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  @blocker %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["acceptance", "kind", "reason", "required_evidence", "handoff", "external_kind"],
    "properties" => %{
      "acceptance" => Map.put(@nonempty_string, "description", "Copy the entire acceptance string verbatim from one criteria entry with adequate=false. Never paraphrase or combine entries."),
      "kind" => %{"type" => "string", "enum" => ["code_defect", "external_condition"]},
      "external_kind" => %{
        "type" => "string",
        "enum" => ["verification", "decision", "not_applicable"],
        "description" => "verification means only real external acceptance evidence is missing; decision means unresolved requirements or scope; code_defect uses not_applicable."
      },
      "reason" => @nonempty_string,
      "required_evidence" => %{"type" => "string"},
      "handoff" => %{"type" => "string"}
    }
  }

  @spec schema(non_neg_integer()) :: map()
  def schema(0) do
    @legacy
    |> Map.put("required", ["approved", "summary", "criteria", "blockers"])
    |> put_in(
      ["properties"],
      %{
        "approved" => %{"type" => "boolean"},
        "summary" => %{"type" => "string"},
        "criteria" => %{"type" => "array", "items" => @criterion},
        "blockers" => %{"type" => "array", "items" => @blocker}
      }
    )
  end

  def schema(_) do
    @legacy
    |> Map.put("required", ["approved", "summary", "criteria", "blockers"])
    |> put_in(
      ["properties"],
      %{
        "approved" => %{"type" => "boolean"},
        "summary" => %{"type" => "string"},
        "criteria" => %{"type" => "array", "items" => @criterion, "minItems" => 1},
        "blockers" => %{"type" => "array", "items" => @blocker}
      }
    )
  end

  @spec parse(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def parse(text, limit) do
    with {:ok, value} <- StructuredOutput.decode(text),
         true <- valid?(value, limit) do
      {:ok, value}
    else
      _ -> {:error, :mvp_invalid_review}
    end
  end

  @doc "Instructions for the semantic constraints that JSON Schema alone cannot express."
  @spec protocol_instructions() :: String.t()
  def protocol_instructions do
    "Every blockers[i].acceptance must copy the ENTIRE criteria[j].acceptance string verbatim, " <>
      "including its ID, behavior, punctuation and whitespace, from one entry with adequate=false. " <>
      "Do not paraphrase, shorten, or combine multiple acceptance entries into a blocker title. " <>
      "When one defect affects multiple criteria, emit a separate blocker for each criterion using its exact acceptance string. " <>
      "Every inadequate criterion must have at least one matching blocker; adequate criteria must have none. " <>
      "Keep the defect explanation in reason. An approved review requires every criterion adequate=true and blockers=[]."
  end

  @doc "Explain an invalid full review without repairing, extracting, or accepting any part of it."
  @spec validation_errors(String.t(), non_neg_integer()) :: [map()]
  def validation_errors(text, limit) do
    case StructuredOutput.decode(text) do
      {:ok, value} ->
        review_errors(value, limit)

      {:error, _} ->
        [
          %{
            "path" => "$",
            "code" => "invalid_json",
            "message" => "Return exactly one JSON object, optionally inside a single json code fence covering the entire response, without prose or trailing content."
          }
        ]
    end
  end

  defp review_errors(value, limit) do
    cond do
      valid?(value, limit) -> []
      limit > 0 and linkage_fields?(value) -> linkage_errors(value)
      true -> schema_errors()
    end
  end

  defp linkage_fields?(value) when is_map(value) do
    is_list(value["criteria"]) and value["criteria"] != [] and Enum.all?(value["criteria"], &valid_criterion?/1) and
      is_list(value["blockers"]) and Enum.all?(value["blockers"], &valid_blocker?/1)
  end

  defp linkage_fields?(_), do: false

  defp linkage_errors(value) do
    inadequate = Enum.reject(value["criteria"], & &1["adequate"]) |> Enum.map(& &1["acceptance"])
    references = Enum.map(value["blockers"], & &1["acceptance"])

    unmatched =
      value["blockers"]
      |> Enum.with_index()
      |> Enum.reject(fn {blocker, _} -> blocker["acceptance"] in inadequate end)
      |> Enum.map(fn {blocker, index} ->
        %{
          "path" => "blockers[#{index}].acceptance",
          "code" => "unmatched_acceptance",
          "actual" => blocker["acceptance"],
          "expected" => inadequate,
          "message" => "Copy one inadequate criterion's full acceptance string verbatim; do not combine or paraphrase criteria."
        }
      end)

    missing =
      value["criteria"]
      |> Enum.with_index()
      |> Enum.filter(fn {criterion, _} -> not criterion["adequate"] and criterion["acceptance"] not in references end)
      |> Enum.map(fn {criterion, index} ->
        %{
          "path" => "criteria[#{index}].acceptance",
          "code" => "missing_blocker",
          "expected" => criterion["acceptance"],
          "message" => "Add a blocker whose acceptance exactly equals this inadequate criterion's acceptance."
        }
      end)

    case unmatched ++ missing do
      [] -> schema_errors()
      errors -> errors
    end
  end

  defp schema_errors,
    do: [%{"path" => "$", "code" => "invalid_review_schema", "message" => "Match the required schema and approval rules exactly; a valid JSON document alone is insufficient."}]

  @doc "Returns the conservative next step for a parsed review. Missing classification means code repair."
  @spec disposition(map()) :: :approved | :repair_code | :awaiting_external
  def disposition(%{"approved" => true} = review) do
    if Map.get(review, "blockers", []) == [], do: :approved, else: :repair_code
  end

  def disposition(%{"approved" => false, "blockers" => blockers}) when is_list(blockers) and blockers != [] do
    if valid_external_conditions?(blockers), do: :awaiting_external, else: :repair_code
  end

  def disposition(_review), do: :repair_code

  @doc "Returns external-condition blockers from a review; absent or malformed lists yield an empty list."
  @spec external_conditions(map()) :: [map()]
  def external_conditions(%{"blockers" => blockers}) when is_list(blockers) do
    Enum.filter(blockers, &match?(%{"kind" => "external_condition"}, &1))
  end

  def external_conditions(_review), do: []

  @doc "Validates a non-empty list of strict external-condition blocker objects."
  @spec valid_external_conditions?(term()) :: boolean()
  def valid_external_conditions?(conditions) when is_list(conditions) and conditions != [] do
    Enum.all?(conditions, &(valid_blocker?(&1) and &1["kind"] == "external_condition"))
  end

  def valid_external_conditions?(_conditions), do: false

  @doc "Only an explicitly classified, valid external-verification review may deliver an unaccepted draft."
  @spec external_draft?(map()) :: boolean()
  def external_draft?(review) do
    valid?(review, 1) and disposition(review) == :awaiting_external and
      Enum.all?(review["blockers"], &(&1["external_kind"] == "verification"))
  end

  # In single-turn review (limit == 0), criteria and blockers are optional audit traces.
  # They may be either string summaries or structured criteria/blocker objects.
  # Safety against invalid approval is enforced:
  # 1. When approved is true, blockers must be empty ([]).
  # 2. When approved is true and criteria is a structured list, every criterion must be adequate=true.
  # 3. disposition/1 routes any non-empty blocker list directly to :repair_code.
  # Type checks (is_boolean/is_binary) are evaluated before any boolean logic on their values
  # to prevent ArgumentError when approved is not a boolean.
  defp valid?(%{"approved" => approved, "summary" => summary} = value, 0) do
    criteria = Map.get(value, "criteria")

    is_boolean(approved) and is_binary(summary) and byte_size(summary) > 0 and
      Map.keys(value) -- ["approved", "summary", "criteria", "blockers"] == [] and
      valid_single_turn_list?(criteria) and
      valid_single_turn_list?(value["blockers"]) and
      (not approved or Map.get(value, "blockers", []) == []) and
      (not approved or criteria_adequate?(criteria))
  end

  defp valid?(%{"approved" => approved, "summary" => summary} = value, _limit) do
    is_boolean(approved) and nonempty?(summary) and valid_fields?(value)
  end

  defp valid?(_, _), do: false

  # When approved is true and criteria contains structured map entries, all must have adequate=true.
  # String-summary entries are not checked (they carry no adequate field).
  defp criteria_adequate?(nil), do: true

  defp criteria_adequate?(list) when is_list(list) do
    Enum.all?(list, fn
      item when is_map(item) -> item["adequate"] == true
      _ -> true
    end)
  end

  defp criteria_adequate?(_), do: true

  defp valid_single_turn_list?(nil), do: true

  defp valid_single_turn_list?(list) when is_list(list) do
    Enum.all?(list, fn
      item when is_binary(item) -> String.trim(item) != ""
      item when is_map(item) -> item != %{}
      _ -> false
    end)
  end

  defp valid_single_turn_list?(_), do: false

  defp valid_fields?(value) do
    criteria = value["criteria"]
    blockers? = Map.has_key?(value, "blockers")

    map_size(value) in [3, 4] and Map.keys(value) -- ["approved", "summary", "criteria", "blockers"] == [] and
      is_list(criteria) and criteria != [] and
      Enum.all?(criteria, &valid_criterion?/1) and
      (not value["approved"] or Enum.all?(criteria, & &1["adequate"])) and
      (not blockers? or valid_blockers?(value["blockers"], criteria, value["approved"]))
  end

  defp valid_blockers?(blockers, criteria, approved?) when is_list(blockers) do
    inadequate = criteria |> Enum.reject(& &1["adequate"]) |> Enum.map(& &1["acceptance"])

    Enum.all?(blockers, &valid_blocker?/1) and
      (not approved? or blockers == []) and
      Enum.all?(blockers, &(&1["acceptance"] in inadequate)) and
      Enum.all?(inadequate, fn acceptance -> Enum.any?(blockers, &(&1["acceptance"] == acceptance)) end)
  end

  defp valid_blockers?(_blockers, _criteria, _approved?), do: false

  defp valid_blocker?(
         %{
           "acceptance" => acceptance,
           "kind" => kind,
           "reason" => reason,
           "required_evidence" => required_evidence,
           "handoff" => handoff
         } = blocker
       ) do
    valid_blocker_shape?(blocker, kind) and nonempty?(acceptance) and nonempty?(reason) and
      kind in ["code_defect", "external_condition"] and
      if kind == "external_condition",
        do: nonempty?(required_evidence) and nonempty?(handoff),
        else: optional_note?(required_evidence) and optional_note?(handoff)
  end

  defp valid_blocker?(_blocker), do: false

  # Historical five-field reviews remain readable, but cannot authorize early delivery.
  defp valid_blocker_shape?(blocker, kind) do
    keys = ~w(acceptance kind reason required_evidence handoff)

    case Map.fetch(blocker, "external_kind") do
      :error ->
        Enum.sort(Map.keys(blocker)) == Enum.sort(keys)

      {:ok, value} ->
        Enum.sort(Map.keys(blocker)) == Enum.sort(["external_kind" | keys]) and
          if(kind == "external_condition", do: value in ["verification", "decision"], else: value == "not_applicable")
    end
  end

  defp valid_criterion?(%{"acceptance" => acceptance, "tests" => tests, "assertion_strength" => strength, "failure_sensitivity" => sensitivity, "adequate" => adequate} = value) do
    map_size(value) == 5 and nonempty?(acceptance) and nonempty?(strength) and nonempty?(sensitivity) and
      is_boolean(adequate) and is_list(tests) and Enum.all?(tests, &nonempty?/1) and
      (not adequate or tests != [])
  end

  defp valid_criterion?(_), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_note?(value), do: value == "" or nonempty?(value)
end
