defmodule SymphonyElixir.Mvp.ExternalHandoff do
  @moduledoc "Immutable external-condition handoffs and operator-supplied evidence snapshots."

  alias SymphonyElixir.Mvp.{Receipt, Review}

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @max_file_bytes 10 * 1_024 * 1_024
  @max_total_bytes 32 * 1_024 * 1_024

  @doc "Persist a pending handoff and its frozen execution bindings without replacing earlier handoffs."
  @spec write(map(), map(), String.t()) :: {:ok, map(), map()} | {:error, term()}
  def write(context, fields, workspace_sha256) when is_map(context) and is_map(fields) do
    conditions = fields["conditions"]

    with true <- Review.valid_external_conditions?(conditions),
         true <- Regex.match?(@sha256, workspace_sha256),
         :ok <- File.mkdir_p(Path.join(context.evidence, "external-handoffs")) do
      id = handoff_id()
      path = Path.join([context.evidence, "external-handoffs", id <> ".json"])
      record = Map.merge(frozen_context(context), fields) |> Map.merge(%{"id" => id, "schema" => 1, "status" => "pending", "workspace_sha256" => workspace_sha256})
      raw = Jason.encode!(record, pretty: true)
      persist_record(context, path, record, raw)
    else
      _ -> {:error, :mvp_external_handoff_invalid}
    end
  rescue
    _ -> {:error, :mvp_external_handoff_invalid}
  end

  defp persist_record(context, path, record, raw) do
    case File.write(path, raw, [:exclusive, :sync]) do
      :ok ->
        handoff = Map.merge(record, %{"record_path" => path, "record_sha256" => digest(raw)})
        persist_receipt(context, record, handoff)

      {:error, reason} ->
        {:error, {:mvp_external_handoff_write, reason}}
    end
  end

  defp persist_receipt(context, record, handoff) do
    old = Receipt.read(context.receipt)
    source_history = Map.get(old, "external_review_history", [])

    entry =
      Map.take(record, ["id", "source", "round", "candidate_sha", "source_digest", "source_data", "conditions", "started_at"])

    :ok =
      Receipt.update(context.receipt, "awaiting_external", %{
        "external_handoff" => handoff,
        "external_review_history" => source_history ++ [entry],
        "reason" => ":mvp_awaiting_external"
      })

    {:ok, record, handoff}
  end

  @doc "Read and verify the immutable handoff pointed to by the current receipt."
  @spec read(map(), map()) :: {:ok, map()} | {:error, atom()}
  def read(context, %{"id" => id, "record_path" => path, "record_sha256" => sha} = handoff)
      when is_binary(id) and is_binary(path) and is_binary(sha) do
    root = Path.expand(Path.join(context.evidence, "external-handoffs"))
    expected_path = Path.expand(Path.join(root, id <> ".json"))

    with true <- Regex.match?(~r/\Aexternal-[0-9]+-[a-zA-Z0-9_-]{8,32}\z/, id),
         true <- Path.expand(path) == expected_path,
         true <- Regex.match?(@sha256, sha),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, raw} <- File.read(path),
         true <- digest(raw) == sha,
         {:ok, record} <- Jason.decode(raw),
         true <- is_map(record) and record["id"] == id and record["status"] == "pending",
         true <- Map.drop(handoff, ["record_path", "record_sha256", "provided_evidence"]) == record do
      {:ok, record}
    else
      _ -> {:error, :mvp_external_handoff_mismatch}
    end
  rescue
    _ -> {:error, :mvp_external_handoff_mismatch}
  end

  def read(_context, _handoff), do: {:error, :mvp_external_handoff_mismatch}

  @doc "Verify operator evidence hashes, copy files to the exclusive audit directory, and return safe paths."
  @spec copy_evidence(Path.t(), [map()], term(), term()) :: {:ok, [map()]} | {:error, atom()}
  def copy_evidence(operation_directory, conditions, supplied, history) do
    with :ok <- validate_evidence(conditions, supplied, history),
         :ok <- File.mkdir(Path.join(operation_directory, "external-evidence")),
         {:ok, copied} <- copy_entries(operation_directory, supplied) do
      {:ok, copied}
    else
      _ -> {:error, :mvp_external_evidence_invalid}
    end
  rescue
    _ -> {:error, :mvp_external_evidence_invalid}
  end

  @doc "Check exact condition coverage, source-file hashes and prior evidence snapshots without writing files."
  @spec validate_evidence([map()], term(), term()) :: :ok | {:error, atom()}
  def validate_evidence(conditions, supplied, history) do
    with true <- Review.valid_external_conditions?(conditions),
         true <- valid_entries?(conditions, supplied),
         true <- valid_history?(history),
         {:ok, sizes} <- source_sizes(supplied),
         true <- Enum.sum(sizes) <= @max_total_bytes,
         true <- snapshot_is_new?(history, supplied) do
      :ok
    else
      _ -> {:error, :mvp_external_evidence_invalid}
    end
  end

  @doc "Encode frozen Git metadata for the JSON receipt."
  @spec encode_git_metadata(map()) :: {:ok, map()} | {:error, atom()}
  def encode_git_metadata(metadata) when is_map(metadata) do
    Enum.reduce_while(metadata, {:ok, %{}}, fn
      {path, {:ok, bytes}}, {:ok, acc} when is_binary(path) and is_binary(bytes) ->
        {:cont, {:ok, Map.put(acc, path, Base.encode64(bytes))}}

      {path, {:error, :enoent}}, {:ok, acc} when is_binary(path) ->
        {:cont, {:ok, Map.put(acc, path, nil)}}

      _, _ ->
        {:halt, {:error, :mvp_external_handoff_invalid}}
    end)
  end

  def encode_git_metadata(_metadata), do: {:error, :mvp_external_handoff_invalid}

  defp frozen_context(context) do
    {:ok, git_metadata} = encode_git_metadata(context.metadata)
    receipt = Receipt.read(context.receipt)

    %{
      "base_sha" => context.base,
      "branch" => context.branch,
      "repository" => %{"repo" => context.repository.repo, "base" => context.repository.base, "url" => context.repository.url},
      "issue_id" => context.issue.id,
      "issue_native_ref" => context.issue.native_ref,
      "issue_scope" => string_scope(context.issue),
      "workspace" => context.workspace,
      "models" => Map.new(context.models, fn {key, value} -> {to_string(key), value} end),
      "services" => Map.get(context, :services),
      "max_rework" => context.limit,
      "checks" => context.settings.checks,
      "recovery_policy" => json(context.settings.recovery),
      "recovery_started_at" => receipt["recovery"]["started_at"],
      "recovery_state" => receipt["recovery"],
      "usage" => receipt["usage"],
      "rework_count" => receipt["rework_count"],
      "execution_sandbox" => json(Map.get(context.settings, :sandbox, %{enabled: false})),
      "git_metadata" => git_metadata,
      "baseline_sha256" => Base.encode16(context.baseline_digest, case: :lower),
      "external_wait_ms" => receipt["recovery"]["external_wait_ms"] || 0
    }
  end

  defp string_scope(issue) do
    issue
    |> Map.take([:id, :identifier, :title, :description])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp valid_entries?(conditions, supplied) when is_list(supplied) do
    acceptances = conditions |> Enum.map(& &1["acceptance"]) |> Enum.uniq()

    all_valid =
      Enum.all?(supplied, fn
        %{"acceptance" => acceptance, "path" => path, "sha256" => sha} = entry ->
          map_size(entry) == 3 and acceptance in acceptances and is_binary(path) and Path.type(path) == :absolute and
            is_binary(sha) and Regex.match?(@sha256, sha)

        _ ->
          false
      end)

    all_valid and Enum.sort(Enum.map(supplied, & &1["acceptance"])) == Enum.sort(acceptances) and
      length(Enum.uniq_by(supplied, & &1["acceptance"])) == length(acceptances)
  end

  defp valid_entries?(_conditions, _supplied), do: false

  defp valid_history?(history) when is_list(history) do
    Enum.all?(history, fn snapshot ->
      is_list(snapshot) and Enum.all?(snapshot, &valid_historical_entry?/1)
    end)
  end

  defp valid_history?(_history), do: false

  defp valid_historical_entry?(%{"acceptance" => acceptance, "sha256" => sha}) do
    is_binary(acceptance) and String.trim(acceptance) != "" and is_binary(sha) and Regex.match?(@sha256, sha)
  end

  defp valid_historical_entry?(_entry), do: false

  defp copy_entries(operation_directory, supplied) do
    Enum.with_index(supplied, 1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, copied} ->
      case copy_one(operation_directory, entry, index) do
        {:ok, result} -> {:cont, {:ok, copied ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp source_sizes(supplied) do
    Enum.reduce_while(supplied, {:ok, []}, fn entry, {:ok, sizes} ->
      case source_size(entry) do
        {:ok, size} -> {:cont, {:ok, sizes ++ [size]}}
        error -> {:halt, error}
      end
    end)
  end

  defp source_size(entry) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(entry["path"]),
         {:ok, bytes} <- File.read(entry["path"]),
         true <- byte_size(bytes) == size and digest(bytes) == entry["sha256"] do
      {:ok, size}
    else
      _ -> {:error, :mvp_external_evidence_invalid}
    end
  end

  defp copy_one(operation_directory, entry, index) do
    source = entry["path"]
    target = Path.join([operation_directory, "external-evidence", "evidence-#{index}.bin"])

    with {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(source),
         {:ok, bytes} <- File.read(source),
         true <- byte_size(bytes) <= @max_file_bytes and digest(bytes) == entry["sha256"],
         :ok <- File.write(target, bytes, [:exclusive, :sync]) do
      {:ok, %{"acceptance" => entry["acceptance"], "source_path" => source, "path" => target, "sha256" => entry["sha256"], "size" => byte_size(bytes)}}
    else
      _ -> {:error, :mvp_external_evidence_invalid}
    end
  end

  defp snapshot_is_new?(history, entries) do
    previous = history |> List.flatten() |> evidence_hashes() |> MapSet.new()
    current = evidence_hashes(entries) |> MapSet.new()

    MapSet.size(MapSet.difference(current, previous)) > 0
  end

  defp evidence_hashes(entries), do: Enum.map(entries, & &1["sha256"])

  defp handoff_id do
    suffix = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    "external-#{System.system_time(:millisecond)}-#{suffix}"
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
