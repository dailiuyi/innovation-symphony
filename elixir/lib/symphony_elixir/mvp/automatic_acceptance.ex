defmodule SymphonyElixir.Mvp.AutomaticAcceptance do
  @moduledoc "Candidate-bound, opt-in fixed probes. Never executes commands supplied by an Issue or Review."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Mvp.{ExecutionSandbox, Executor, ModelServices, Receipt, Recovery}
  alias SymphonyElixir.PathSafety

  @spec valid_profiles?(term()) :: boolean()
  def valid_profiles?(profiles) when is_map(profiles) do
    map_size(profiles) <= 16 and Enum.all?(profiles, fn {name, profile} -> valid_name?(name) and valid_profile?(profile) end)
  end

  def valid_profiles?(_), do: false

  defp valid_name?(name), do: is_binary(name) and byte_size(name) in 1..128

  defp valid_profile?(profile) when is_map(profile) do
    Enum.sort(Map.keys(profile)) == ~w(kind runner_sha256 timeout_ms) and
      profile["kind"] in ~w(linux gpt_coder gpt_reviewer) and
      is_binary(profile["runner_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, profile["runner_sha256"]) and
      is_integer(profile["timeout_ms"]) and profile["timeout_ms"] in 1..60_000
  end

  defp valid_profile?(_), do: false

  @spec runner_digest(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def runner_digest(context, "linux") do
    with {:ok, raw} <- File.read(Path.join(context.settings.sandbox["trusted_root"], "scripts/probe_rootless.py")), do: {:ok, digest(raw)}
  end

  def runner_digest(_, kind) when kind in ~w(gpt_coder gpt_reviewer) do
    objects = Enum.map([__MODULE__, ModelServices, AppServer], &:code.get_object_code/1)
    if Enum.all?(objects, &match?({_, _, _}, &1)), do: {:ok, digest(Enum.map_join(objects, fn {_, bytes, _} -> bytes end))}, else: {:error, :probe_runner_unavailable}
  end

  def runner_digest(_, _), do: {:error, :unregistered_acceptance_probe}

  @spec prepare(map()) :: {:ok, String.t(), map()} | {:error, term()}
  def prepare(context) do
    profiles = Map.get(context.settings.sandbox, "acceptance_profiles", %{})
    data = Receipt.read(context.receipt)

    with true <- context.settings.sandbox["backend"] == "rootless" and Recovery.enabled?(context.settings),
         true <- valid_profiles?(profiles),
         true <- data["status"] == "awaiting_external",
         true <- not File.exists?(Path.join(context.evidence, "operator-recheck.lock")),
         {:ok, raw} <- File.read(context.receipt),
         {:ok, record} <- Executor.validate_external_probe(context, digest(raw)),
         conditions when is_list(conditions) and conditions != [] <- record["conditions"],
         true <- Enum.all?(conditions, &Map.has_key?(profiles, &1["acceptance"])),
         directory = Path.join([context.evidence, "acceptance-jobs", record["id"]]),
         true <- PathSafety.canonicalize(directory) == {:ok, directory},
         :ok <- File.mkdir_p(Path.dirname(directory)),
         :ok <- File.mkdir(directory) do
      binding = Map.take(record, ~w(id candidate_sha execution_sandbox services models workspace_sha256 started_at))
      write!(directory, "job.json", %{"schema" => 1, "status" => "started", "binding" => binding, "profiles" => profiles})
      result = run_probes(context, conditions, profiles, directory, binding)
      write!(directory, "completion.json", %{"status" => if(match?({:ok, _}, result), do: "completed", else: "stopped"), "result" => inspect(result)})

      with {:ok, evidence} <- result, {:ok, raw} <- File.read(context.receipt) do
        authorization = %{
          "id" => "acceptance-" <> record["id"],
          "authorization" => "Frozen, explicitly enabled fixed acceptance profiles",
          "runtime_version" => record["candidate_sha"],
          "command" => ["internal", "automatic_acceptance"],
          "predecessor" => nil,
          "legacy_closures" => [],
          "external_evidence" => evidence
        }

        {:ok, digest(raw), authorization}
      end
    else
      _ -> {:error, :automatic_acceptance_unavailable}
    end
  rescue
    _ -> {:error, :automatic_acceptance_stopped}
  end

  defp run_probes(context, conditions, profiles, directory, binding) do
    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, evidence} ->
      profile = profiles[condition["acceptance"]]
      index = length(evidence)

      with {:ok, expected} <- runner_digest(context, profile["kind"]),
           true <- expected == profile["runner_sha256"],
           {:ok, timeout} <- probe_timeout(context, profile, binding),
           {:ok, proof} <- timed_probe(context, Map.put(profile, "timeout_ms", timeout), directory, binding, index) do
        path = write!(directory, "probe-#{index}.json", Map.merge(proof, %{"binding" => binding, "profile" => profile}))
        entry = %{"acceptance" => condition["acceptance"], "path" => path, "sha256" => digest(File.read!(path))}
        {:cont, {:ok, evidence ++ [entry]}}
      else
        _ -> {:halt, {:error, :automatic_acceptance_probe_failed}}
      end
    end)
  end

  defp probe_timeout(context, profile, binding) do
    data = Receipt.read(context.receipt)
    recovery = data["recovery"]

    with {:ok, started, _} <- DateTime.from_iso8601(recovery["started_at"]),
         {:ok, waiting, _} <- DateTime.from_iso8601(binding["started_at"]) do
      uncharged = Map.get(data, "external_probe_ms", 0) - Map.get(data, "external_probe_charged_ms", 0)
      active = DateTime.diff(waiting, started, :millisecond) - (recovery["external_wait_ms"] || 0) + uncharged
      remaining = context.settings.recovery.max_elapsed_ms - active
      if active >= 0 and remaining > 0, do: {:ok, min(remaining, profile["timeout_ms"])}, else: {:error, :probe_budget_exhausted}
    end
  end

  defp timed_probe(context, profile, directory, binding, index) do
    data = Receipt.read(context.receipt)
    :ok = Receipt.update(context.receipt, data["status"], %{"external_probe_inflight" => true})
    started = System.monotonic_time(:millisecond)
    result = probe(context, profile, directory, binding, index)
    elapsed = System.monotonic_time(:millisecond) - started
    current = Receipt.read(context.receipt)
    :ok = Receipt.update(context.receipt, current["status"], %{"external_probe_inflight" => false, "external_probe_ms" => Map.get(current, "external_probe_ms", 0) + elapsed})
    result
  end

  defp probe(context, %{"kind" => "linux", "timeout_ms" => timeout}, directory, _binding, index) do
    result = ExecutionSandbox.check(context, ["python3", "scripts/probe_rootless.py"], timeout, Path.join(directory, "linux-#{index}.log"))
    if result == {:ok, 0}, do: {:ok, %{"status" => "passed", "kind" => "linux"}}, else: {:error, result}
  end

  defp probe(context, profile, directory, binding, index) do
    role = if profile["kind"] == "gpt_coder", do: :coder, else: :reviewer
    data = Receipt.read(context.receipt)
    count = Map.get(data, "external_probe_calls", 0)
    # Keep one real model call for the required independent Review after checks.
    with true <- data["recovery"]["agent_attempts"] + count + 1 < context.settings.recovery.max_agent_attempts,
         {:ok, options} <- ModelServices.options(context, role),
         true <- String.starts_with?(options[:model] || "", "gpt-") do
      Receipt.update(context.receipt, data["status"], %{"external_probe_calls" => count + 1})
      nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      expected = %{"probe" => nonce, "candidate_sha" => binding["candidate_sha"]}
      prompt = "Fixed model connection probe. Return exactly this JSON object without using tools or running commands: " <> Jason.encode!(expected)
      messages = Path.join(directory, "model-#{index}.jsonl")
      handler = fn message -> File.write!(messages, Jason.encode!(%{"message" => inspect(message, limit: :infinity)}) <> "\n", [:append, :sync]) end
      started = System.monotonic_time(:millisecond)
      result = ExecutionSandbox.agent(context, :acceptance, prompt, options ++ [tools: false, read_only: true, on_message: handler, wall_timeout_ms: profile["timeout_ms"]])
      elapsed = System.monotonic_time(:millisecond) - started

      with {:ok, response} <- result, {:ok, ^expected} <- Jason.decode(response[:output_text] || "") do
        {:ok,
         %{
           "status" => "passed",
           "kind" => profile["kind"],
           "role" => Atom.to_string(role),
           "service" => context.services[Atom.to_string(role)],
           "elapsed_ms" => elapsed,
           "response" => Map.drop(response, [:output_text])
         }}
      else
        _ -> {:error, :model_probe_failed}
      end
    else
      _ -> {:error, :model_probe_budget_or_service_unavailable}
    end
  end

  defp write!(directory, name, value) do
    path = Path.join(directory, name)
    File.write!(path, Jason.encode!(value, pretty: true), [:exclusive, :sync])
    path
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
