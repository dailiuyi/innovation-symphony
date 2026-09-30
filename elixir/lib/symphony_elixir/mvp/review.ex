defmodule SymphonyElixir.Mvp.Review do
  @moduledoc "Structured review contract, including acceptance-to-test evidence in rework mode."

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
      "acceptance" => %{"type" => "string"},
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
    "required" => ["acceptance", "kind", "reason", "required_evidence", "handoff"],
    "properties" => %{
      "acceptance" => @nonempty_string,
      "kind" => %{"type" => "string", "enum" => ["code_defect", "external_condition"]},
      "reason" => @nonempty_string,
      "required_evidence" => %{"type" => "string"},
      "handoff" => %{"type" => "string"}
    }
  }

  @spec schema(non_neg_integer()) :: map()
  def schema(0), do: @legacy

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
    with {:ok, value} <- Jason.decode(text),
         true <- valid?(value, limit) do
      {:ok, value}
    else
      _ -> {:error, :mvp_invalid_review}
    end
  end

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

  defp valid?(%{"approved" => approved, "summary" => summary} = value, 0) do
    map_size(value) == 2 and is_boolean(approved) and is_binary(summary) and byte_size(summary) > 0
  end

  defp valid?(%{"approved" => approved, "summary" => summary} = value, _limit) do
    is_boolean(approved) and nonempty?(summary) and valid_fields?(value)
  end

  defp valid?(_, _), do: false

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
    map_size(blocker) == 5 and nonempty?(acceptance) and nonempty?(reason) and
      kind in ["code_defect", "external_condition"] and
      if kind == "external_condition",
        do: nonempty?(required_evidence) and nonempty?(handoff),
        else: optional_note?(required_evidence) and optional_note?(handoff)
  end

  defp valid_blocker?(_blocker), do: false

  defp valid_criterion?(%{"acceptance" => acceptance, "tests" => tests, "assertion_strength" => strength, "failure_sensitivity" => sensitivity, "adequate" => adequate} = value) do
    map_size(value) == 5 and nonempty?(acceptance) and nonempty?(strength) and nonempty?(sensitivity) and
      is_boolean(adequate) and is_list(tests) and Enum.all?(tests, &nonempty?/1) and
      (not adequate or tests != [])
  end

  defp valid_criterion?(_), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_note?(value), do: value == "" or nonempty?(value)
end
