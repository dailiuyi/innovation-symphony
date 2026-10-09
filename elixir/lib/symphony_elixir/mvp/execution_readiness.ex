defmodule SymphonyElixir.Mvp.ExecutionReadiness do
  @moduledoc "Read-only admission before a durable claim; readiness never asserts candidate acceptance."

  alias SymphonyElixir.Mvp.{AutomaticAcceptance, Commands, ExecutionSandbox, Intake, ModelServices, Recovery}

  @sandbox_keys ~w(root toolchain codex dependencies trusted_root image worker profile network memory_mb disk_mb pids cpus environment_recipe)

  @spec settings(term()) :: {:ok, map()} | {:error, atom()}
  def settings(nil), do: {:ok, %{enabled: false}}
  def settings(%{"enabled" => false} = value) when map_size(value) == 1, do: settings(nil)

  def settings(%{"enabled" => true, "required_backend" => "rootless", "required_acceptances" => names} = value) do
    if Enum.sort(Map.keys(value)) == ~w(enabled required_acceptances required_backend) and
         is_list(names) and length(names) <= 16 and names == Enum.uniq(names) and
         Enum.all?(names, &(is_binary(&1) and byte_size(&1) in 1..128)) do
      {:ok, %{enabled: true, required_backend: "rootless", required_acceptances: names}}
    else
      {:error, :invalid_execution_readiness}
    end
  end

  def settings(_), do: {:error, :invalid_execution_readiness}

  @spec enabled?(map()) :: boolean()
  def enabled?(settings), do: get_in(settings, [:execution_readiness, :enabled]) == true

  @spec backend_ready?(map()) :: boolean()
  def backend_ready?(settings) do
    not enabled?(settings) or
      (get_in(settings, [:sandbox, :enabled]) == true and
         get_in(settings, [:sandbox, "backend"]) == settings.execution_readiness.required_backend)
  end

  @spec prepare(map(), map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def prepare(issue, settings, opts) do
    if enabled?(settings) do
      with :ok <- require_backend(settings),
           {:ok, models} <- Intake.resolve(issue, settings, opts),
           {:ok, services} <- ModelServices.freeze(models, settings),
           models = Map.put(models, :services, services),
           {:ok, report} <- check(settings, models, opts) do
        {:ok, Map.put(models, :readiness, report)}
      end
    else
      {:ok, nil}
    end
  end

  @spec defaults(map(), keyword()) :: :ok | {:error, term()}
  def defaults(settings, opts) do
    if enabled?(settings) do
      with :ok <- require_backend(settings),
           {:ok, models} <- Intake.resolve_comments([], settings),
           {:ok, services} <- ModelServices.freeze(models, settings),
           {:ok, _} <- check(settings, Map.put(models, :services, services), opts),
           do: :ok
    else
      :ok
    end
  end

  @spec check(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(settings, models, opts \\ []) do
    context = %{
      settings: settings,
      services: models.services,
      models: models,
      workspace: settings.execution_workspace_root,
      evidence: settings.state_dir
    }

    with :ok <- require_backend(settings),
         :ok <- roles(context, opts),
         :ok <- acceptances(context),
         {:ok, kinds} <- check_kinds(settings.checks),
         request = request(settings, kinds),
         raw = Jason.encode!(request),
         {:ok, output} <- bridge(settings, raw, opts),
         {:ok, report} <- validate_report(output, raw, kinds) do
      {:ok, Map.put(report, "services_sha256", digest(Jason.encode!(models.services)))}
    end
  end

  defp require_backend(settings) do
    if backend_ready?(settings), do: :ok, else: {:error, :execution_readiness_backend_mismatch}
  end

  defp roles(context, opts) do
    resolver = Keyword.get(opts, :readiness_role_options, &ModelServices.options/2)

    Enum.reduce_while([:coder, :reviewer], :ok, fn role, :ok ->
      with {:ok, options} <- resolver.(context, role),
           service when is_map(service) <- options[:model_service],
           command when is_binary(command) <- service["command"],
           [binary, "app-server" | _] <- OptionParser.split(command),
           true <- binary == context.settings.sandbox["codex"],
           :ok <- ModelServices.identity_matches(service),
           {:ok, _} <- ModelServices.credential(service["credential_ref"]),
           :ok <- ModelServices.connection_ready(service) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:execution_readiness_role, role, reason}}}
        _ -> {:halt, {:error, {:execution_readiness_role, role, :native_client_mismatch}}}
      end
    end)
  end

  defp acceptances(context) do
    required = context.settings.execution_readiness.required_acceptances
    profiles = Map.get(context.settings.sandbox, "acceptance_profiles", %{})

    if required != [] and not Recovery.enabled?(context.settings) do
      {:error, :execution_readiness_requires_recovery}
    else
      Enum.reduce_while(required, :ok, &acceptance(context, profiles, &1, &2))
    end
  end

  defp acceptance(context, profiles, name, :ok) do
    with profile when is_map(profile) <- profiles[name],
         {:ok, sha} <- AutomaticAcceptance.runner_digest(context, profile["kind"]),
         true <- sha == profile["runner_sha256"],
         :ok <- probe_role(context, profile["kind"]) do
      {:cont, :ok}
    else
      _ -> {:halt, {:error, {:execution_readiness_acceptance_unavailable, name}}}
    end
  end

  defp probe_role(context, kind) when kind in ~w(gpt_coder gpt_reviewer) do
    role = if kind == "gpt_coder", do: "coder", else: "reviewer"
    if String.starts_with?(context.services[role]["model"] || "", "gpt-"), do: :ok, else: {:error, :unsupported_probe_model}
  end

  defp probe_role(_, "linux"), do: :ok

  defp check_kinds(checks) do
    Enum.reduce_while(checks, {:ok, []}, &check_kind/2)
  end

  defp check_kind(argv, {:ok, kinds}) do
    case ExecutionSandbox.check_kind(argv) do
      {:ok, kind} when kind in ~w(candidate baseline view) -> {:cont, {:ok, Enum.uniq(kinds ++ [kind])}}
      _ -> {:halt, {:error, :execution_readiness_unsupported_check}}
    end
  end

  defp request(settings, kinds) do
    sandbox = settings.sandbox |> Map.put_new("environment_recipe", "") |> Map.take(@sandbox_keys)
    %{"sandbox" => sandbox, "state_dir" => settings.state_dir, "workspace_root" => settings.execution_workspace_root, "checks" => kinds}
  end

  defp bridge(settings, raw, opts) do
    script = Path.join(settings.sandbox["trusted_root"], "scripts/execution_sandbox.sh")
    argv = ["bash", script, "--readiness", raw]
    cwd = Path.dirname(settings.workflow_path)

    case Keyword.fetch(opts, :readiness_command_run) do
      {:ok, runner} -> runner.(argv, cwd, 60_000)
      :error -> bounded_bridge(settings, argv, cwd, Keyword.get(opts, :readiness_timeout_ms, 65_000))
    end
  end

  defp bounded_bridge(settings, argv, cwd, deadline) when is_integer(deadline) and deadline > 0 do
    # GNU timeout bounds the OS child. Queued SCM_RIGHTS descriptors can keep
    # stdout alive afterwards, so independently bound System.cmd's EOF wait.
    task =
      Task.async(fn ->
        try do
          Commands.run(argv, cwd, 60_000, secret_environment_names: settings.secret_environment_names)
        rescue
          _ -> {:error, :execution_readiness_bridge_failed}
        end
      end)

    case Task.yield(task, deadline) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:execution_readiness_timeout, deadline}}
    end
  end

  defp bounded_bridge(_, _, _, _), do: {:error, :execution_readiness_invalid_timeout}

  defp validate_report(output, raw, kinds) do
    expected = digest(raw)
    names = ~w(task_roots trusted_inventory toolchain runtime image) ++ if("view" in kinds, do: ["view"], else: [])

    case Jason.decode(output) do
      {:ok,
       %{
         "schema" => 1,
         "backend" => "rootless",
         "profile" => "rootless-open-v1",
         "request_sha256" => ^expected,
         "formal_acceptance" => false,
         "status" => "ready",
         "blockers" => [],
         "checks" => checks
       } = report}
      when is_list(checks) and checks != [] ->
        if complete_checks?(checks, names), do: {:ok, report}, else: {:error, :execution_readiness_invalid_report}

      {:ok, %{"request_sha256" => ^expected, "status" => "blocked", "blockers" => blockers}} when is_list(blockers) and blockers != [] ->
        {:error, {:execution_readiness_blocked, blockers}}

      _ ->
        {:error, :execution_readiness_invalid_report}
    end
  end

  defp complete_checks?(checks, names) do
    Enum.all?(checks, &valid_check?/1) and Enum.sort(Enum.map(checks, & &1["name"])) == Enum.sort(names)
  end

  defp valid_check?(%{"name" => name, "status" => "passed", "detail" => detail}), do: is_binary(name) and is_binary(detail)
  defp valid_check?(_), do: false

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
