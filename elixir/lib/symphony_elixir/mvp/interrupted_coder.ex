defmodule SymphonyElixir.Mvp.InterruptedCoder do
  @moduledoc "Evidence binding for a diagnosed check repair interrupted by a host boot change."

  alias SymphonyElixir.Mvp.Recovery

  @max_bytes 16 * 1_024 * 1_024
  @frozen ~w(repository issue workspace branch base_sha models services max_rework issue_scope execution_sandbox)

  @spec evidence(map(), map()) :: {:ok, map(), map()} | {:error, atom()}
  def evidence(context, data) do
    last = List.last(data["rounds"])
    previous = Enum.at(data["rounds"], -2)
    events = data["recovery"]["events"]
    count = data["recovery"]["agent_attempts"]

    with true <- Enum.all?(data["rounds"], &is_nil(&1["review"])),
         true <- previous["candidate_sha"] == data["candidate_sha"],
         true <- Enum.all?(~w(candidate_sha review review_path comment check_failure), &is_nil(last[&1])),
         failure when is_map(failure) <- previous["check_failure"],
         {:ok, checks} <- checks(context, previous, failure),
         {:ok, attempts} <- attempts(data, count),
         [diagnosis_start, diagnosis_finish, coder_start] <- Enum.take(events, -3),
         true <- diagnosis_start["role"] == "diagnosis" and diagnosis_start["attempt"] == count - 1,
         true <- diagnosis_start["evidence"] == Path.join(previous["evidence"], "agent-attempt-#{count - 1}"),
         true <- diagnosis_finish["status"] == "finished" and coder_start["role"] == "coder",
         true <- coder_start["evidence"] == Path.join(last["evidence"], "agent-attempt-#{count}"),
         {:ok, output} <- read(Path.join(diagnosis_start["evidence"], "output.txt")),
         {:ok, diagnosis} <- Recovery.parse(output, get_in(data, ["services", "coder"])),
         true <- diagnosis["action"] == "repair_code",
         feedback_event when is_map(feedback_event) <- Enum.at(events, -4),
         feedback when is_map(feedback) <- feedback_event["feedback"],
         true <- feedback_event["round"] == previous["round"] and feedback["kind"] == "check",
         true <- Map.drop(feedback, ["kind", "operator_diagnostic"]) == failure do
      evidence = %{"checks" => checks, "attempts" => attempts}
      {:ok, evidence, Map.put(feedback, "diagnosis", diagnosis)}
    else
      _ -> {:error, :mvp_interruption_evidence_mismatch}
    end
  rescue
    _ -> {:error, :mvp_interruption_evidence_mismatch}
  end

  defp checks(context, round, failure) do
    index = failure["index"]

    if is_integer(index) and index in 1..length(context.settings.checks) do
      context.settings.checks
      |> Enum.take(index)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, &append_check(context, round, failure, &1, &2))
    else
      {:error, :checks}
    end
  end

  defp append_check(context, round, failure, {argv, number}, {:ok, entries}) do
    case check(context, round, failure, argv, number) do
      {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
      error -> {:halt, error}
    end
  end

  defp check(context, round, failure, argv, number) do
    directory = round["evidence"]
    path = Path.join(directory, "check-#{number}.json")
    log = Path.join(directory, "check-#{number}.log")

    expected =
      Enum.map(argv, &(&1 |> String.replace("{workspace}", context.workspace) |> String.replace("{baseline}", Path.join(context.evidence, "baseline")) |> String.replace("{evidence}", directory)))

    with {:ok, raw} <- read(path),
         {:ok, report} <- Jason.decode(raw),
         true <- report["index"] == number and report["argv"] == expected and report["log_path"] == log,
         true <- valid_check_result?(report, failure, number),
         {:ok, log_bytes} <- read(log) do
      {:ok, %{"path" => path, "sha256" => digest(raw), "log_path" => log, "log_sha256" => digest(log_bytes)}}
    else
      _ -> {:error, :check}
    end
  end

  defp valid_check_result?(report, %{"index" => number} = failure, number),
    do: report == failure and (is_nil(report["exit_status"]) or report["exit_status"] != 0)

  defp valid_check_result?(report, _failure, _number), do: report["exit_status"] == 0 and report["repairable"] == false

  defp attempts(data, count) do
    starts = Enum.filter(data["recovery"]["events"], &(&1["status"] == "started"))
    finishes = Enum.filter(data["recovery"]["events"], &(&1["status"] == "finished"))

    with true <- length(starts) == count and length(finishes) == count - 1,
         true <- Enum.map(starts, & &1["attempt"]) == Enum.to_list(1..count) do
      Enum.reduce_while(starts, {:ok, []}, &append_attempt(data, &1, finishes, count, &2))
    else
      _ -> {:error, :attempts}
    end
  end

  defp append_attempt(data, start, finishes, count, {:ok, entries}) do
    finished = Enum.filter(finishes, &(&1["usage_key"] == start["usage_key"]))

    case attempt(data, start, finished, count) do
      {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
      error -> {:halt, error}
    end
  end

  defp attempt(data, start, finished, count) do
    key = "#{start["role"]}_attempt_#{start["attempt"]}"
    round = Enum.find(data["rounds"], &Map.has_key?(&1["usage"], key))
    path = start["evidence"]

    with true <- start["role"] in ["coder", "diagnosis"] and start["usage_key"] == key,
         true <- is_map(round) and path == Path.join(round["evidence"], "agent-attempt-#{start["attempt"]}"),
         true <- is_integer(start["stage_attempt"]) and start["stage_attempt"] >= 1 and start["stage_attempt"] <= data["recovery"]["policy"]["stage_attempts"],
         {:ok, prompt} <- read(Path.join(path, "prompt.txt")),
         {:ok, messages} <- read(Path.join(path, "messages.log")),
         {:ok, result_files} <- attempt_result(path, start["attempt"] == count, finished) do
      {:ok, Map.merge(%{"attempt" => start["attempt"], "directory" => path, "prompt_sha256" => digest(prompt), "messages_sha256" => digest(messages)}, result_files)}
    else
      _ -> {:error, :attempt}
    end
  end

  defp attempt_result(path, true, []) do
    if not File.exists?(Path.join(path, "output.txt")) and not File.exists?(Path.join(path, "outcome.json")),
      do: {:ok, %{"unfinished" => true}},
      else: {:error, :unfinished}
  end

  defp attempt_result(path, false, [finish]) do
    with {:ok, output} <- read(Path.join(path, "output.txt")),
         {:ok, raw} <- read(Path.join(path, "outcome.json")),
         {:ok, outcome} <- Jason.decode(raw),
         true <- outcome["outcome"] == finish["outcome"] and is_binary(outcome["result"]),
         true <- String.starts_with?(outcome["outcome"], "{:ok,") do
      {:ok, %{"output_sha256" => digest(output), "outcome_sha256" => digest(raw)}}
    else
      _ -> {:error, :outcome}
    end
  end

  defp attempt_result(_path, _open, _finished), do: {:error, :attempt_result}

  @doc "Authenticate a completed interrupted continuation whose coder exhausted the original wall budget."
  @spec timeout_evidence(map(), map()) :: {:ok, map(), map(), pos_integer()} | {:error, atom()}
  def timeout_evidence(context, data) do
    id = data["operator_recheck"]

    with true <- matches?(id, ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/),
         directory = Path.join([context.evidence, "operator-rechecks", id]),
         {:ok, ^directory} <- SymphonyElixir.PathSafety.canonicalize(directory),
         {:ok, authorization_raw} <- read(Path.join(directory, "authorization.json")),
         {:ok, authorization} <- Jason.decode(authorization_raw),
         {:ok, before_raw} <- read(Path.join(directory, "receipt-before.json")),
         {:ok, before} <- Jason.decode(before_raw),
         {:ok, completion_raw} <- read(Path.join(directory, "completion.json")),
         {:ok, completion} <- Jason.decode(completion_raw),
         {:ok, current_raw} <- read(context.receipt),
         {:ok, ^data} <- Jason.decode(current_raw),
         true <- authorization["id"] == id and authorization["receipt_sha256"] == digest(before_raw),
         true <- timeout_completion?(completion, id, current_raw),
         true <- timeout_history?(before, data),
         {:ok, prior, feedback} <- evidence(context, before),
         true <- authorization["interruption_evidence"] == prior,
         true <- authorization["interruption_evidence_digest"] == digest(Jason.encode!(prior)),
         {:ok, owner} <- owner(context, before, authorization),
         true <- authorization["interrupted_owner"] == owner,
         resume = Enum.at(data["recovery"]["events"], length(before["recovery"]["events"])),
         true <- resume == interruption_event(before, authorization),
         {:ok, timeout, next_stage} <- timeout_attempt(before, data, id) do
      proof = %{
        "authorization_sha256" => digest(authorization_raw),
        "receipt_before_sha256" => digest(before_raw),
        "completion_sha256" => digest(completion_raw),
        "prior_evidence" => prior,
        "owner" => owner,
        "timeout" => timeout
      }

      {:ok, proof, feedback, next_stage}
    else
      _ -> {:error, :mvp_interruption_timeout_evidence_mismatch}
    end
  rescue
    _ -> {:error, :mvp_interruption_timeout_evidence_mismatch}
  end

  defp timeout_completion?(completion, id, raw) do
    completion["id"] == id and completion["final_receipt_sha256"] == digest(raw) and
      completion["result"] == "{:error, :mvp_recovery_resource_exhausted}"
  end

  defp interruption_event(before, authorization) do
    owner = authorization["interrupted_owner"]

    %{
      "kind" => "operator_interrupted_coder_resume",
      "operation_id" => authorization["id"],
      "attempt" => before["recovery"]["agent_attempts"],
      "round" => length(before["rounds"]),
      "previous_boot_id" => owner["previous_boot_id"],
      "current_boot_id" => owner["current_boot_id"],
      "workspace_digest" => authorization["workspace_digest"],
      "interruption_evidence_digest" => authorization["interruption_evidence_digest"]
    }
  end

  defp timeout_history?(before, data) do
    before["status"] == "coding" and data["status"] == "blocked" and
      data["reason"] == ":mvp_recovery_resource_exhausted" and frozen_history?(before, data) and
      before["candidate_sha"] == data["candidate_sha"] and before["rework_count"] == data["rework_count"] and
      Enum.drop(before["rounds"], -1) == Enum.drop(data["rounds"], -1) and
      Map.drop(List.last(before["rounds"]), ~w(usage model_requests)) == Map.drop(List.last(data["rounds"]), ~w(usage model_requests)) and
      timeout_requests?(before, data)
  end

  defp timeout_requests?(before, data) do
    previous = List.last(before["rounds"])["model_requests"]
    current = List.last(data["rounds"])["model_requests"]

    case get_in(before, ["services", "coder"]) do
      nil ->
        previous == current

      service ->
        key = "coder_attempt_#{before["recovery"]["agent_attempts"] + 1}"
        request = Map.take(service, ~w(id version provider model credential_ref source)) |> Map.put("actual_model", nil)
        current == Map.put(previous || %{}, key, request)
    end
  end

  defp timeout_attempt(before, data, id) do
    old_events = before["recovery"]["events"]
    prior_start = List.last(old_events)
    count = before["recovery"]["agent_attempts"] + 1

    with [resume, start, finish] <- Enum.drop(data["recovery"]["events"], length(old_events)),
         true <- resume["kind"] == "operator_interrupted_coder_resume" and resume["operation_id"] == id,
         true <- resume["attempt"] == count - 1 and resume["round"] == length(data["rounds"]),
         true <- data["recovery"]["agent_attempts"] == count,
         true <- start["role"] == "coder" and start["status"] == "started" and start["attempt"] == count,
         true <- start["stage_attempt"] == prior_start["stage_attempt"] + 1,
         true <- start["usage_key"] == "coder_attempt_#{count}",
         true <- timeout_usage?(before, data, start["usage_key"]),
         true <- finish == %{"status" => "finished", "usage_key" => start["usage_key"], "outcome" => "{:error, :mvp_recovery_resource_exhausted}"},
         path = Path.join(List.last(data["rounds"])["evidence"], "agent-attempt-#{count}"),
         true <- start["evidence"] == path,
         {:ok, files} <- timeout_files(path) do
      {:ok, files, start["stage_attempt"] + 1}
    else
      _ -> {:error, :timeout_attempt}
    end
  end

  defp timeout_usage?(before, data, key) do
    usage = List.last(data["rounds"])["usage"]
    Map.has_key?(usage, key) and Map.delete(usage, key) == List.last(before["rounds"])["usage"]
  end

  defp timeout_files(path) do
    with {:ok, prompt} <- read(Path.join(path, "prompt.txt")),
         {:ok, messages} <- read(Path.join(path, "messages.log")),
         {:ok, ""} <- read(Path.join(path, "output.txt")),
         {:ok, raw} <- read(Path.join(path, "outcome.json")),
         {:ok, %{"result" => "{:error, :wall_timeout}", "outcome" => "{:error, :mvp_recovery_resource_exhausted}"}} <- Jason.decode(raw) do
      {:ok, %{"directory" => path, "prompt_sha256" => digest(prompt), "messages_sha256" => digest(messages), "outcome_sha256" => digest(raw)}}
    else
      _ -> {:error, :timeout_files}
    end
  end

  @doc "Read operator-owned historical records and independently observe the current boot and ownership."
  @spec owner(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def owner(context, data, authorization) do
    with %{watchdog: watchdog_path, task: task_path, workflow: workflow} <- Map.get(context, :interruption_owner_record),
         {:ok, watchdog_raw, watchdog} <- bound_record(context, watchdog_path, authorization["previous_owner"]),
         {:ok, task_raw, task} <- bound_record(context, task_path, authorization["task_owner"]),
         process when is_map(process) <- watchdog["process"],
         true <- process["workflow"] == workflow and watchdog["service"] == workflow,
         true <- valid_process?(process) and task["pid"] == process["pid"],
         true <- Enum.any?(task["state"]["running"] || [], &(&1["issue_id"] == data["issue"] and &1["workspace_path"] == data["workspace"])),
         old when is_map(old) <- task_receipt(task, context.receipt),
         true <- frozen_history?(old, data),
         {:ok, boot} <- Keyword.get(context.opts, :interruption_boot, &current_boot/0).(),
         true <- boot != process["boot_id"],
         :ok <- Keyword.get(context.opts, :interruption_active_owner, &active_owner/1).(context) do
      {:ok,
       %{
         "previous_boot_id" => process["boot_id"],
         "current_boot_id" => boot,
         "previous_pid" => process["pid"],
         "previous_owner_sha256" => digest(watchdog_raw),
         "task_owner_sha256" => digest(task_raw)
       }}
    else
      _ -> {:error, :mvp_interruption_owner_mismatch}
    end
  rescue
    _ -> {:error, :mvp_interruption_owner_mismatch}
  end

  defp bound_record(context, path, %{"path" => path, "sha256" => sha}) do
    with true <- Path.type(path) == :absolute and not String.starts_with?(Path.expand(path), Path.expand(context.workspace) <> "/"),
         {:ok, ^path} <- SymphonyElixir.PathSafety.canonicalize(path),
         {:ok, raw} <- read(path),
         true <- digest(raw) == sha,
         {:ok, value} <- Jason.decode(raw),
         true <- is_map(value) do
      {:ok, raw, value}
    else
      _ -> {:error, :owner_record}
    end
  end

  defp bound_record(_context, _path, _supplied), do: {:error, :owner_record}

  defp task_receipt(task, receipt) do
    case Enum.filter(task["gh7_receipts"] || [], &(&1["path"] == receipt)) do
      [entry] -> entry["receipt"]
      _ -> nil
    end
  end

  defp frozen_history?(old, data) do
    Map.take(old, @frozen) == Map.take(data, @frozen) and
      get_in(old, ["recovery", "started_at"]) == get_in(data, ["recovery", "started_at"]) and
      get_in(old, ["recovery", "policy"]) == get_in(data, ["recovery", "policy"]) and
      events_prefix?(old["recovery"]["events"], data["recovery"]["events"]) and
      rounds_prefix?(old["rounds"], data["rounds"])
  end

  defp events_prefix?(old, current),
    do: is_list(old) and old != [] and Enum.take(current, length(old)) == old

  defp rounds_prefix?(old, current) do
    is_list(old) and old != [] and length(old) <= length(current) and
      Enum.all?(Enum.zip(old, current), fn {before, current} ->
        Map.take(before, ~w(round base_sha models services evidence checks)) == Map.take(current, ~w(round base_sha models services evidence checks))
      end)
  end

  defp valid_process?(process) do
    is_integer(process["pid"]) and process["pid"] > 0 and
      matches?(process["boot_id"], ~r/\A[0-9a-f-]{36}\z/) and
      matches?(process["start_ticks"], ~r/\A[0-9]+\z/) and
      matches?(process["version"], ~r/\A[0-9a-f]{40}\z/) and valid_process_command?(process)
  end

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp valid_process_command?(process) do
    is_binary(process["install"]) and is_list(process["cmdline"]) and
      Path.join(process["install"], "bin/symphony") in process["cmdline"] and
      process["workflow"] in process["cmdline"]
  end

  defp current_boot do
    with {:ok, bytes} <- File.read("/proc/sys/kernel/random/boot_id"), do: {:ok, String.trim(bytes)}
  end

  defp active_owner(context) do
    url = Map.get(context, :interruption_status_url)

    with true <- is_binary(url) and String.starts_with?(url, "http://127.0.0.1:"),
         {:ok, %{status: 200, body: state}} <- Req.get(url, receive_timeout: 5_000, retry: false),
         true <- is_map(state) and is_list(state["running"]) and is_list(state["retrying"]),
         false <- Enum.any?(state["running"] ++ state["retrying"], &(&1["issue_id"] == context.issue.id)),
         false <- process_in_workspace?(context) do
      :ok
    else
      _ -> {:error, :active_owner}
    end
  end

  defp process_in_workspace?(context) do
    root = Keyword.get(context.opts, :interruption_proc_root, "/proc")

    Enum.any?(Path.wildcard(Path.join(root, "[0-9]*")), fn process ->
      cwd = File.read_link(Path.join(process, "cwd"))
      command = File.read(Path.join(process, "cmdline"))

      match?({:ok, value} when value == context.workspace, cwd) or
        case command do
          {:ok, bytes} -> String.contains?(bytes, context.workspace) or String.contains?(bytes, context.receipt)
          {:error, :enoent} -> false
          {:error, _} -> true
        end
    end)
  end

  defp read(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @max_bytes do
      File.read(path)
    else
      _ -> {:error, :evidence_file}
    end
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
