defmodule SymphonyElixir.Mvp.ReviewProtocol do
  @moduledoc "Bind a stopped review protocol stage to its original attempts and successful checks."

  alias SymphonyElixir.Mvp.Review

  @max_evidence_bytes 2 * 1_024 * 1_024

  @spec evidence(map(), map()) :: {:ok, map()} | {:error, atom()}
  def evidence(context, data) do
    with false <- previously_rejected?(data),
         {:ok, attempts} <- attempts(context, data),
         {:ok, checks} <- checks(context, data) do
      {:ok, %{"attempts" => attempts, "checks" => checks, "output" => List.last(attempts)["output"]}}
    else
      true -> {:error, :mvp_review_already_rejected}
      _ -> {:error, :mvp_review_protocol_evidence_mismatch}
    end
  end

  defp previously_rejected?(data) do
    Enum.any?(data["rounds"], fn round ->
      round["candidate_sha"] == data["candidate_sha"] and get_in(round, ["review", "approved"]) == false
    end)
  end

  defp attempts(context, data) do
    recovery = data["recovery"]
    count = recovery["agent_attempts"]
    cap = context.settings.recovery.stage_attempts
    recent = Enum.take(recovery["events"], -2 * cap)

    if length(recent) == 2 * cap and count >= cap do
      collect_attempts(context, data, recent, count - cap)
    else
      {:error, :attempts}
    end
  end

  defp collect_attempts(context, data, recent, offset) do
    recent
    |> Enum.chunk_every(2)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {pair, stage}, {:ok, entries} ->
      case attempt(context, List.last(data["rounds"]), pair, offset + stage, stage) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp attempt(context, round, [start, finish], number, stage) do
    directory = Path.join(round["evidence"], "agent-attempt-#{number}")
    key = "reviewer_attempt_#{number}"

    with true <- start["attempt"] == number and start["stage_attempt"] == stage,
         true <- start["role"] == "reviewer" and start["status"] == "started",
         true <- start["evidence"] == directory and start["usage_key"] == key,
         true <- finish["usage_key"] == key and finish["status"] == "finished",
         true <- finish["outcome"] == "{:error, :mvp_invalid_review}",
         true <- Map.has_key?(round["usage"], key),
         {:ok, prompt} <- read(Path.join(directory, "prompt.txt")),
         {:ok, output} <- read(Path.join(directory, "output.txt")),
         {:ok, outcome_raw} <- read(Path.join(directory, "outcome.json")),
         {:ok, outcome} <- Jason.decode(outcome_raw),
         true <- outcome["outcome"] == finish["outcome"],
         {:error, :mvp_invalid_review} <- Review.parse(output, context.limit) do
      {:ok,
       %{
         "attempt" => number,
         "directory" => directory,
         "prompt_sha256" => digest(prompt),
         "output_sha256" => digest(output),
         "outcome_sha256" => digest(outcome_raw),
         "output" => output
       }}
    else
      _ -> {:error, :attempt}
    end
  end

  defp checks(context, data) do
    directory = check_directory(context, data)

    context.settings.checks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {command, index}, {:ok, entries} ->
      case check(context, directory, command, index) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp check_directory(context, %{"operator_recheck" => id}) when is_binary(id),
    do: Path.join([context.evidence, "operator-rechecks", id])

  defp check_directory(_context, data), do: List.last(data["rounds"])["evidence"]

  defp check(context, directory, command, index) do
    path = Path.join(directory, "check-#{index}.json")
    log = Path.join(directory, "check-#{index}.log")

    expected =
      Enum.map(command, &(&1 |> String.replace("{workspace}", context.workspace) |> String.replace("{baseline}", Path.join(context.evidence, "baseline")) |> String.replace("{evidence}", directory)))

    with {:ok, raw} <- read(path),
         {:ok, report} <- Jason.decode(raw),
         true <- report["index"] == index and report["argv"] == expected,
         true <- report["exit_status"] == 0 and report["repairable"] == false and report["log_path"] == log,
         {:ok, %{type: :regular}} <- File.lstat(log) do
      {:ok, %{"path" => path, "sha256" => digest(raw), "log_path" => log}}
    else
      _ -> {:error, :check}
    end
  end

  defp read(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @max_evidence_bytes do
      File.read(path)
    else
      _ -> {:error, :evidence_file}
    end
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
