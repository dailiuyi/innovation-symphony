defmodule SymphonyElixir.Mvp.StructuredOutput do
  @moduledoc """
  Decodes a complete role result, optionally wrapped in one JSON code fence.

  Some channels stop enforcing JSON Schema when tools are declared. Only a
  single fence covering the entire response is tolerated; callers still own
  semantic validation and tool evidence requirements.
  """

  @fence ~r/\A[ \t\r\n]*```json[ \t]*\r?\n(.*?)\r?\n```[ \t\r\n]*\z/s

  @spec decode(term()) :: {:ok, term()} | {:error, :invalid_json}
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> decode_fenced(text)
    end
  end

  def decode(_text), do: {:error, :invalid_json}

  defp decode_fenced(text) do
    with [_, body] <- Regex.run(@fence, text),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value}
    else
      _ -> {:error, :invalid_json}
    end
  end
end
