defmodule SymphonyElixir.Mvp.DeepSeek do
  @moduledoc "DeepSeek Responses discovery; inference and tools use the isolated Codex Responses provider."
  alias SymphonyElixir.Mvp.{ModelServices, StructuredOutput}

  @doc "Normalize a complete DeepSeek Responses result; never extract JSON from prose or change other channels."
  @spec normalize_structured_output(term(), map() | nil) :: term()
  def normalize_structured_output(text, %{"provider" => "deepseek", "adapter" => "deepseek_responses", "connection" => %{"protocol" => "responses"}}) do
    case StructuredOutput.decode(text) do
      {:ok, value} -> Jason.encode!(value)
      {:error, _} -> text
    end
  end

  def normalize_structured_output(text, _service), do: text

  @spec list_models(map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_models(service, opts \\ []) do
    with :ok <- ModelServices.identity_matches(service),
         {:ok, {:env, _, key}} <- ModelServices.credential(service["credential_ref"]),
         {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) <-
           Req.get(service["connection"]["base_url"] <> "/models", auth: {:bearer, key}, retry: false, redirect: false, receive_timeout: 15_000, plug: Keyword.get(opts, :plug)),
         true <- Enum.all?(models, &(is_map(&1) and ModelServices.identifier?(&1["id"]))) do
      # /models does not attest reasoning controls. Administrators must register
      # channel-specific controls and verify the exact role/parameter combination.
      {:ok, Enum.map(models, &%{"model" => &1["id"], "supportedReasoningEfforts" => [], "reasoningMode" => "unknown"})}
    else
      _ -> {:error, :model_discovery_failed}
    end
  end
end
