defmodule SymphonyElixir.Mvp.OperatorRecheck do
  @moduledoc "Exclusive, append-only operator recheck evidence with a durable completion chain."

  @legacy ["operator_check_resume", "operator_rework_extension"]

  @doc "Keep legacy entrypoints mutually exclusive and unavailable once a recheck has started."
  @spec legacy(map(), (-> term())) :: term()
  def legacy(context, run) do
    lock = Path.join(context.evidence, "operator-recheck.lock")

    with false <- File.exists?(Path.join(context.evidence, "operator-rechecks")),
         :ok <- File.write(lock, "legacy", [:exclusive, :sync]) do
      result =
        if File.exists?(Path.join(context.evidence, "operator-rechecks")),
          do: {:error, :mvp_recheck_guard_or_audit_mismatch},
          else: run.()

      File.rm!(lock)
      result
    else
      _ -> {:error, :mvp_recheck_guard_or_audit_mismatch}
    end
  end

  @spec begin(map(), binary(), map(), map()) :: {:ok, map()} | {:error, term()}
  def begin(context, raw, data, authorization) do
    root = Path.join(context.evidence, "operator-rechecks")
    lock = Path.join(context.evidence, "operator-recheck.lock")

    with true <- valid_authorization?(authorization),
         directory = Path.join(root, authorization["id"]),
         false <- File.exists?(directory),
         :ok <- predecessor(root, raw, data, authorization),
         {:ok, closures} <- legacy_closures(raw, data, authorization),
         :ok <- File.write(lock, authorization["id"], [:exclusive, :sync]) do
      operation = %{root: root, directory: directory, lock: lock, receipt: context.receipt, id: authorization["id"]}
      accept(operation, context, raw, data, authorization, closures)
    else
      _ -> {:error, :mvp_recheck_guard_or_audit_mismatch}
    end
  end

  @spec complete(map(), term()) :: :ok
  def complete(operation, result) do
    completion = %{
      "id" => operation.id,
      "result" => inspect(result),
      "final_receipt_sha256" => digest(File.read!(operation.receipt)),
      "completed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    write_json!(Path.join(operation.directory, "completion.json"), completion)
    head = Path.join(operation.root, "head.json")
    File.write!(head <> ".next", Jason.encode!(completion, pretty: true), [:sync])
    File.rename!(head <> ".next", head)
    File.rm!(operation.lock)
    :ok
  end

  defp accept(operation, context, raw, data, authorization, closures) do
    # Repeat the raw-byte and predecessor checks after acquiring the execution-wide lock.
    with {:ok, ^raw} <- File.read(context.receipt),
         :ok <- predecessor(operation.root, raw, data, authorization) do
      File.mkdir_p!(operation.root)
      :ok = File.mkdir(operation.directory)
      File.write!(Path.join(operation.directory, "receipt-before.json"), raw, [:exclusive, :sync])

      audit =
        Map.merge(authorization, %{
          "receipt_sha256" => digest(raw),
          "checks" => context.settings.checks,
          "issue_scope" => Map.take(context.issue, [:id, :identifier, :title, :description]),
          "legacy_closure_evidence" => closures,
          "started_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

      write_json!(Path.join(operation.directory, "authorization.json"), audit)
      {:ok, operation}
    else
      _ ->
        File.rm!(operation.lock)
        {:error, :mvp_recheck_receipt_changed}
    end
  end

  defp valid_authorization?(audit) when is_map(audit) do
    valid_id?(audit["id"]) and nonempty?(audit["authorization"]) and valid_invocation?(audit) and
      is_list(audit["legacy_closures"]) and Enum.all?(audit["legacy_closures"], &is_map/1)
  end

  defp valid_authorization?(_), do: false

  defp valid_invocation?(audit) do
    is_binary(audit["runtime_version"]) and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, audit["runtime_version"]) and
      is_list(audit["command"]) and audit["command"] != [] and Enum.all?(audit["command"], &nonempty?/1) and
      (is_nil(audit["diagnostic"]) or nonempty?(audit["diagnostic"]))
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}\z/, id)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp predecessor(root, raw, data, audit) do
    case File.read(Path.join(root, "head.json")) do
      {:error, :enoent} ->
        if is_nil(audit["predecessor"]) and is_nil(data["operator_recheck"]), do: :ok, else: {:error, :predecessor}

      {:ok, bytes} ->
        with {:ok, head} <- Jason.decode(bytes),
             true <- is_map(head) and valid_id?(head["id"]),
             true <- head["id"] == audit["predecessor"] and head["id"] == data["operator_recheck"],
             true <- head["final_receipt_sha256"] == digest(raw),
             {:ok, completion} <- File.read(Path.join([root, head["id"], "completion.json"])),
             {:ok, ^head} <- Jason.decode(completion) do
          :ok
        else
          _ -> {:error, :predecessor}
        end

      _ ->
        {:error, :predecessor}
    end
  end

  defp legacy_closures(raw, data, audit) do
    if is_nil(audit["predecessor"]) do
      kinds = Enum.filter(@legacy, &(not is_nil(data[&1])))
      supplied = audit["legacy_closures"]

      with true <- Enum.map(supplied, & &1["kind"]) == kinds,
           true <- legacy_guards?(data, kinds),
           {:ok, evidence} <- verify_closures(supplied, data, raw) do
        {:ok, evidence}
      else
        _ -> {:error, :legacy_closure}
      end
    else
      if audit["legacy_closures"] == [], do: {:ok, []}, else: {:error, :legacy_closure}
    end
  end

  defp legacy_guards?(data, kinds) do
    # Derive the evidence root from the round, not an operator-provided closure path.
    root = data["rounds"] |> hd() |> Map.fetch!("evidence") |> Path.dirname()

    Enum.all?(@legacy, fn kind ->
      File.regular?(Path.join(root, String.replace(kind, "_", "-") <> ".lock")) == kind in kinds
    end)
  end

  defp verify_closures(closures, data, raw) do
    closures
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {closure, index}, {:ok, verified} ->
      next = Enum.at(closures, index + 1)

      target = if next, do: File.read(Path.join(data[next["kind"]]["evidence"], "receipt-before.json")), else: {:ok, raw}

      case verify_closure(closure, data, target) do
        {:ok, evidence} -> {:cont, {:ok, verified ++ [evidence]}}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_closure(closure, data, target) do
    with {:ok, pid_raw, pid} <- evidence(closure["pid_record"]),
         {:ok, process_raw, process} <- evidence(closure["process_result"]),
         {:ok, result_raw, result} <- evidence(closure["result"]),
         {:ok, receipt_raw, receipt} <- evidence(closure["final_receipt"]),
         true <- process_origin?(closure, pid),
         {:ok, ^receipt_raw} <- target,
         {:ok, before} <- File.read(Path.join(data[closure["kind"]]["evidence"], "receipt-before.json")),
         true <- digest(before) == data[closure["kind"]]["receipt_sha256"],
         true <- process_ended?(pid, process),
         true <- result_matches?(result, receipt) do
      {:ok,
       %{
         "kind" => closure["kind"],
         "input_receipt_sha256" => digest(before),
         "pid_record" => pid_raw,
         "process_result" => process_raw,
         "result" => result_raw,
         "final_receipt" => receipt_raw,
         "verified_at" => DateTime.to_iso8601(DateTime.utc_now())
       }}
    else
      _ -> {:error, :legacy_closure}
    end
  end

  defp evidence(%{"path" => path, "sha256" => sha}) when is_binary(path) and is_binary(sha) do
    with {:ok, raw} <- File.read(path),
         true <- digest(raw) == sha,
         {:ok, decoded} <- Jason.decode(raw),
         true <- is_map(decoded) do
      {:ok, raw, decoded}
    else
      _ -> {:error, :evidence}
    end
  end

  defp evidence(_), do: {:error, :evidence}

  defp process_origin?(closure, pid) do
    nonempty?(pid["operation"]) and
      Enum.all?(["pid_record", "process_result", "result"], fn key ->
        Path.dirname(Path.expand(closure[key]["path"])) == Path.expand(pid["operation"])
      end)
  end

  defp process_ended?(pid, process) do
    is_integer(pid["pid"]) and pid["pid"] > 0 and nonempty?(pid["operation"]) and nonempty?(pid["release"]) and
      is_integer(process["exit_code"]) and process["exit_code"] >= 0 and
      File.dir?("/proc") and File.lstat("/proc/#{pid["pid"]}") == {:error, :enoent}
  end

  defp result_matches?(result, receipt) do
    receipt["status"] == "blocked" and is_binary(receipt["reason"]) and
      Map.take(result, ["status", "candidate_sha", "rework_count", "pull_request"]) ==
        Map.new(["status", "candidate_sha", "rework_count", "pull_request"], &{&1, receipt[&1]}) and
      result["result"] == "{:error, " <> receipt["reason"] <> "}"
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true), [:exclusive, :sync])
end
