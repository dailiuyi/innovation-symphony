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

  @spec schema(non_neg_integer()) :: map()
  def schema(0), do: @legacy

  def schema(_) do
    @legacy
    |> Map.put("required", ["approved", "summary", "criteria"])
    |> put_in(["properties", "criteria"], %{"type" => "array", "items" => @criterion, "minItems" => 1})
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

  defp valid?(%{"approved" => approved, "summary" => summary} = value, 0) do
    map_size(value) == 2 and is_boolean(approved) and is_binary(summary) and byte_size(summary) > 0
  end

  defp valid?(%{"approved" => approved, "summary" => summary} = value, _limit) do
    is_boolean(approved) and nonempty?(summary) and valid_fields?(value)
  end

  defp valid?(_, _), do: false

  defp valid_fields?(value) do
    criteria = value["criteria"]

    map_size(value) == 3 and is_list(criteria) and criteria != [] and
      Enum.all?(criteria, &valid_criterion?/1) and
      (not value["approved"] or Enum.all?(criteria, & &1["adequate"]))
  end

  defp valid_criterion?(%{"acceptance" => acceptance, "tests" => tests, "assertion_strength" => strength, "failure_sensitivity" => sensitivity, "adequate" => adequate} = value) do
    map_size(value) == 5 and nonempty?(acceptance) and nonempty?(strength) and nonempty?(sensitivity) and
      is_boolean(adequate) and is_list(tests) and Enum.all?(tests, &nonempty?/1) and
      (not adequate or tests != [])
  end

  defp valid_criterion?(_), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
