defmodule SymphonyElixir.Mvp.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Mvp.StructuredOutput

  @object ~s({"token":"abc"})

  test "decodes bare JSON or one json fence covering the whole response" do
    for text <- [
          @object,
          " \n#{@object}\t\r\n",
          "```json\n#{@object}\n```",
          " \t\r\n```json \t\r\n #{@object} \r\n```\r\n\t "
        ] do
      assert {:ok, %{"token" => "abc"}} = StructuredOutput.decode(text)
    end

    # Semantic validation belongs to the caller, for both formats.
    assert {:ok, []} = StructuredOutput.decode("[]")
    assert {:ok, []} = StructuredOutput.decode("```json\n[]\n```")
  end

  test "rejects prose, multiple or non-json fences, concatenated and incomplete JSON" do
    fenced = "```json\n#{@object}\n```"

    for text <- [
          nil,
          1,
          [],
          %{},
          <<255>>,
          "",
          "no json here",
          "Diagnosis: #{@object}",
          @object <> @object,
          @object <> " trailing",
          "Here is the result:\n" <> fenced,
          fenced <> "\nDone.",
          fenced <> "\n" <> fenced,
          "```text\n#{@object}\n```",
          "```JSON\n#{@object}\n```",
          "```\n#{@object}\n```",
          "```json\n#{@object <> @object}\n```",
          "```json\ntoken: abc\n```",
          "```json\n{\"token\":\n```",
          "```json\n#{@object}",
          "```json #{@object}```",
          "```json\n#{@object}\n````",
          fenced <> "\n" <> @object
        ] do
      assert {:error, :invalid_json} = StructuredOutput.decode(text), inspect(text)
    end
  end
end
