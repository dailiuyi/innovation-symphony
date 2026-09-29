defmodule SymphonyElixir.Mvp.ExecutionSandbox do
  @moduledoc "Task-private execution environments for coder commands and controller checks."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Mvp.Commands
  alias SymphonyElixir.PathSafety

  @paths ~w(root toolchain codex dependencies trusted_root auth_home)
  @limits %{"memory_mb" => 4096, "disk_mb" => 8192, "pids" => 256, "cpus" => 4}
  @ranges %{"memory_mb" => 128..65_536, "disk_mb" => 128..65_536, "pids" => 1..65_536, "cpus" => 1..64}
  @excluded ~w(.git .codex .check-evidence .symphony-import)
  @build_paths ~w(elixir/deps elixir/_build elixir/cover elixir/bin)

  @spec settings(term()) :: {:ok, map()} | {:error, atom()}
  def settings(nil), do: {:ok, %{enabled: false}}

  def settings(%{"enabled" => false} = value) when map_size(value) == 1,
    do: {:ok, %{enabled: false}}

  def settings(%{"enabled" => true} = value) do
    allowed = ["enabled" | @paths] ++ Map.keys(@limits)
    limits = Map.merge(@limits, Map.take(value, Map.keys(@limits)))

    if Map.keys(value) -- allowed == [] and Enum.all?(@paths, &absolute?(value[&1])) and
         Enum.all?(limits, fn {key, limit} -> is_integer(limit) and limit in @ranges[key] end) do
      {:ok, Map.merge(value, limits) |> Map.delete("enabled") |> Map.put(:enabled, true)}
    else
      {:error, :invalid_execution_sandbox}
    end
  end

  def settings(_), do: {:error, :invalid_execution_sandbox}

  @spec enabled?(map()) :: boolean()
  def enabled?(settings), do: get_in(settings, [:sandbox, :enabled]) == true

  @spec agent(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent(context, role, prompt, options) do
    config = context.settings.sandbox
    timeout = Keyword.get(options, :wall_timeout_ms, context.settings.check_timeout_ms)
    import_options = Keyword.put(context.opts, :sandbox_max_bytes, config["disk_mb"] * 1_048_576)

    with {:ok, run} <- prepare(config, context, timeout),
         :ok <- prepare_home(run, config),
         {:ok, before} <- source_files(context.workspace, import_options[:sandbox_max_bytes]) do
      environment = %{id: "task", cwd: "/workspace", codex_home: run.home}
      options = Keyword.put(options, :execution_environment, environment)
      agent = Keyword.get(context.opts, :sandbox_agent_run, &AppServer.run/4)
      result = invoke(fn -> agent.(context.workspace, isolated_prompt(prompt, role, context), context.issue, options) end)

      with {:ok, status} <- await_result(run.scratch, cleanup_timeout(context)),
           :ok <- export_changes(role, run.scratch, context.workspace, before, import_options) do
        agent_result(result, status)
      end
    end
  end

  @spec check(map(), [String.t()], pos_integer(), Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def check(context, command, timeout, log_path) do
    config = context.settings.sandbox

    with {:ok, kind} <- check_kind(command),
         {:ok, run} <- prepare(config, context, timeout) do
      argv =
        launcher(config, context, run.scratch, timeout) ++
          ["--", "python3", "/opt/symphony/scripts/check_isolated.py", kind, "--candidate-sha", Commands.git!(["rev-parse", "HEAD"], context.workspace)]

      # The launcher owns timeouts and descendant cleanup; give it time to export evidence.
      runner = Keyword.get(context.opts, :sandbox_command_run, &Commands.run_logged/4)
      result = invoke(fn -> runner.(argv, context.workspace, timeout + 30_000, log_path) end)

      with {:ok, status} <- await_result(run.scratch, cleanup_timeout(context)),
           :ok <- copy_evidence(run.scratch, log_path, config["disk_mb"] * 1_048_576) do
        check_result(result, status)
      end
    end
  end

  defp prepare(config, context, timeout) do
    root = config["root"]

    with :ok <- validate_paths(config, context) do
      run = Path.join(root, "run-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      :ok = File.mkdir(run)
      :ok = File.chmod(run, 0o700)
      scratch = Path.join(run, "sandbox")
      home = Path.join(run, "codex-home")
      :ok = File.mkdir(home)
      :ok = File.chmod(home, 0o700)
      args = launcher(config, context, scratch, timeout)
      {:ok, %{root: run, scratch: scratch, home: home, argv: args}}
    end
  end

  defp validate_paths(config, context) do
    cond do
      not canonical?(config["root"]) or overlap?(config["root"], context.workspace) ->
        {:error, :sandbox_root_overlaps_workspace}

      not safe_paths?(config, context) ->
        {:error, :sandbox_unsafe_trusted_paths}

      File.lstat(Path.join(context.workspace, ".symphony-import")) != {:error, :enoent} ->
        {:error, :sandbox_import_recovery_required}

      true ->
        :ok
    end
  end

  defp safe_paths?(config, context) do
    trusted = Enum.map(~w(toolchain codex dependencies trusted_root auth_home), &config[&1])
    mounted = [context.workspace, context.evidence, Path.join(context.evidence, "baseline") | Enum.take(trusted, 4)]
    paths = [config["root"] | trusted] ++ mounted

    Enum.all?(paths, &canonical?/1) and
      Enum.all?(trusted, &(not overlap?(&1, context.workspace))) and
      Enum.all?(mounted, &(not overlap?(&1, config["root"]) and not overlap?(&1, config["auth_home"]))) and
      safe_auth_file?(config["auth_home"], mounted)
  end

  defp safe_auth_file?(home, mounted) do
    case PathSafety.canonicalize(Path.join(home, "auth.json")) do
      {:ok, auth} -> Enum.all?(mounted, &(not under?(auth, &1)))
      _ -> false
    end
  end

  defp overlap?(left, right), do: under?(left, right) or under?(right, left)

  defp launcher(config, context, scratch, timeout) do
    [
      "bash",
      Path.join(config["trusted_root"], "scripts/execution_sandbox.sh"),
      "--workspace",
      context.workspace,
      "--scratch-root",
      scratch,
      "--toolchain",
      config["toolchain"],
      "--codex",
      config["codex"],
      "--trusted-root",
      config["trusted_root"],
      "--dependencies",
      config["dependencies"],
      "--baseline",
      Path.join(context.evidence, "baseline"),
      "--evidence",
      context.evidence,
      "--timeout-seconds",
      to_string(max(1, div(timeout, 1000))),
      "--memory-mb",
      to_string(config["memory_mb"]),
      "--disk-mb",
      to_string(config["disk_mb"]),
      "--pids",
      to_string(config["pids"]),
      "--cpus",
      to_string(config["cpus"])
    ]
  end

  defp prepare_home(run, config) do
    auth = Path.join(config["auth_home"], "auth.json")

    with true <- File.regular?(auth),
         :ok <- File.ln_s(auth, Path.join(run.home, "auth.json")) do
      args = tl(run.argv) ++ ["--", "/opt/codex", "exec-server", "--listen", "stdio"]
      environments = "default = \"task\"\ninclude_local = false\n[[environments]]\nid = \"task\"\nprogram = \"/bin/bash\"\nargs = #{Jason.encode!(args)}\ninitialize_timeout_sec = 120\n"
      File.write!(Path.join(run.home, "environments.toml"), environments, [:exclusive])

      File.write!(
        Path.join(run.home, "config.toml"),
        "model_reasoning_effort = \"high\"\nweb_search = \"disabled\"\n[features]\napps = false\nplugins = false\nhooks = false\ncodex_hooks = false\ncode_mode = false\njs_repl = false\nbrowser_use = false\ncomputer_use = false\nskip_host_skill_discovery = true\nmulti_agent = false\nshell_snapshot = false\n",
        [:exclusive]
      )

      :ok
    else
      _ -> {:error, :sandbox_auth_unavailable}
    end
  end

  defp isolated_prompt(prompt, role, context) do
    prompt
    |> String.replace(context.evidence, "/evidence")
    |> String.replace(context.workspace, "/workspace")
    |> role_prompt(role)
  end

  defp role_prompt(prompt, :coder) do
    prompt <>
      "\n\nExecution environment: /workspace is a disposable, offline Linux task sandbox. " <>
      "Local TCP sockets and subprocesses are available. Run tests and diagnostic commands freely here. " <>
      "Run `python3 /opt/symphony/scripts/check_isolated.py candidate` and `python3 /opt/symphony/scripts/check_isolated.py baseline` before finishing. " <>
      "Repair failures and rerun within THIS session. Do not finish with known failing checks. " <>
      "The trusted toolchain, dependencies and baseline are preinstalled; no external credentials or services are available. " <>
      "Do not weaken checks or change their effective policy. Report skipped and unexecuted tests accurately. " <>
      "Do not commit or modify .git. The controller performs a separate full verification and independent Review."
  end

  defp role_prompt(prompt, _), do: prompt <> "\n\nAll repository paths refer to the isolated copy at /workspace; the frozen base is /baseline and controller feedback is read-only at /evidence."

  defp check_kind(["python3", script | _]) do
    case Path.basename(script) do
      "check_candidate.py" -> {:ok, "candidate"}
      "check_baseline.py" -> {:ok, "baseline"}
      _ -> {:error, :unsupported_isolated_check}
    end
  end

  defp check_kind(_), do: {:error, :unsupported_isolated_check}

  defp await_result(scratch, remaining) when remaining > 0 do
    result_path = Path.join(scratch, "result.json")

    case File.lstat(result_path) do
      {:ok, %{type: :regular}} ->
        read_result(result_path, scratch)

      {:error, :enoent} ->
        Process.sleep(50)
        await_result(scratch, remaining - 50)

      _ ->
        {:error, :sandbox_cleanup_incomplete}
    end
  end

  defp await_result(_, _), do: {:error, :sandbox_cleanup_incomplete}

  defp read_result(path, scratch) do
    with true <- canonical?(scratch),
         {:ok, raw} <- File.read(path),
         {:ok, %{"cleanup_complete" => true, "export_complete" => true, "scratch_root" => ^scratch, "exit_status" => status}} <- Jason.decode(raw),
         true <- is_integer(status) and status in 0..255 do
      {:ok, status}
    else
      _ -> {:error, :sandbox_cleanup_incomplete}
    end
  end

  # AppServer normally closes its stdio executor in an after clause. Even when its
  # invocation raises, wait for the launcher's independent descendant-cleanup proof.
  defp invoke(fun) do
    fun.()
  catch
    kind, reason -> {:error, {:sandbox_invocation_failed, kind, reason}}
  end

  defp agent_result({:ok, _}, status) when status != 0, do: {:error, {:sandbox_process_failed, status}}
  defp agent_result(result, _status), do: result
  defp check_result({:ok, status} = result, status), do: result
  defp check_result({:ok, _}, _), do: {:error, :sandbox_check_exit_mismatch}
  defp check_result(result, _), do: result

  defp cleanup_timeout(context), do: Keyword.get(context.opts, :sandbox_cleanup_timeout_ms, 30_000)

  defp export_changes(:coder, scratch, workspace, before, options) do
    export = Path.join(scratch, "export")

    with {:ok, files} <- source_files(export, options[:sandbox_max_bytes]),
         :ok <- unchanged_workspace(workspace, before, options[:sandbox_max_bytes]),
         :ok <- validate_import_paths(workspace, files) do
      import_files(export, workspace, before, files, options)
    end
  end

  defp export_changes(_, _, _, _, _), do: :ok

  defp import_files(export, workspace, before, files, options) do
    transaction = Path.join(workspace, ".symphony-import")
    original = Map.keys(before)
    replacement = Map.keys(files)
    operation = Keyword.get(options, :sandbox_import_file, &import_file/3)

    result =
      invoke(fn ->
        File.mkdir!(transaction)
        journal = %{original: original, replacement: replacement, export: export}
        File.write!(Path.join(transaction, "journal.json"), Jason.encode!(journal), [:exclusive])
        transfer_files(replacement, export, Path.join(transaction, "new"), :copy, operation)
        transfer_files(original, workspace, Path.join(transaction, "backup"), :rename, operation)
        transfer_files(replacement, Path.join(transaction, "new"), workspace, :rename, operation)
        :ok
      end)

    finish_import(result, transaction, workspace, original, replacement)
  end

  defp transfer_files(paths, source, destination, action, operation) do
    Enum.each(paths, fn relative ->
      target = Path.join(destination, relative)
      File.mkdir_p!(Path.dirname(target))

      case operation.(action, Path.join(source, relative), target) do
        :ok -> :ok
        {:error, reason} -> throw({:sandbox_import_io, action, relative, reason})
      end
    end)
  end

  defp import_file(:copy, source, target), do: File.cp(source, target)
  defp import_file(:rename, source, target), do: File.rename(source, target)

  defp finish_import(:ok, transaction, _workspace, _original, _replacement) do
    File.rm_rf(transaction)
    :ok
  end

  defp finish_import(error, transaction, workspace, original, replacement) do
    # Preserve the journal, staged files and any backup that cannot be restored.
    # Rollback uses real filesystem operations, independent of an injected failure.
    rollback =
      invoke(fn ->
        Enum.each(replacement -- original, &rollback_added(&1, transaction, workspace))
        Enum.each(original, &restore_original(&1, transaction, workspace))
        :ok
      end)

    {:error, {:sandbox_import_failed, transaction, error, rollback}}
  end

  defp rollback_added(relative, transaction, workspace) do
    target = Path.join(workspace, relative)

    if File.regular?(target) and not File.exists?(Path.join([transaction, "new", relative])) do
      preserve_failed_file(target, transaction, relative)
    end
  end

  defp restore_original(relative, transaction, workspace) do
    backup = Path.join([transaction, "backup", relative])
    target = Path.join(workspace, relative)

    if File.regular?(backup) do
      if File.exists?(target), do: preserve_failed_file(target, transaction, relative)
      File.rename!(backup, target)
    end
  end

  defp preserve_failed_file(target, transaction, relative) do
    preserved = Path.join([transaction, "failed", relative])
    File.mkdir_p!(Path.dirname(preserved))
    File.rename!(target, preserved)
  end

  defp unchanged_workspace(workspace, before, limit) do
    case source_files(workspace, limit) do
      {:ok, ^before} -> :ok
      _ -> {:error, :sandbox_workspace_changed}
    end
  end

  # Reject file/directory shape changes before deleting anything. A future atomic
  # tree replacement can support these transitions without risking partial import.
  defp validate_import_paths(workspace, files) do
    conflict = Enum.find(Map.keys(files), &(not compatible_import_path?(workspace, &1)))
    if conflict, do: {:error, {:sandbox_import_path_conflict, conflict}}, else: :ok
  end

  defp compatible_import_path?(workspace, relative) do
    parents = relative |> Path.split() |> Enum.drop(-1) |> Enum.scan(fn part, parent -> Path.join(parent, part) end)
    paths = [{relative, :regular} | Enum.map(parents, &{&1, :directory})]
    Enum.all?(paths, &compatible_file_type?(workspace, &1))
  end

  defp compatible_file_type?(workspace, {path, type}) do
    case File.lstat(Path.join(workspace, path)) do
      {:ok, %{type: ^type}} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp copy_evidence(scratch, log_path, limit) do
    source = Path.join([scratch, "export", ".check-evidence"])

    with true <- File.dir?(source) or {:error, :sandbox_check_evidence_missing},
         {:ok, _} <- regular_tree(source, fn _ -> false end, limit) do
      File.cp_r!(source, Path.rootname(log_path) <> "-details")
      :ok
    end
  end

  defp source_files(root, limit) do
    exclude = fn relative ->
      Enum.any?(@excluded ++ @build_paths, &(relative == &1 or String.starts_with?(relative, &1 <> "/")))
    end

    regular_tree(root, exclude, limit)
  end

  defp regular_tree(root, exclude, limit) do
    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, {files, _remaining}} <- walk(root, "", exclude, {%{}, limit}) do
      {:ok, files}
    else
      {:error, :sandbox_source_size_limit} = error -> error
      {:error, {:sandbox_unsupported_file, _}} = error -> error
      _ -> {:error, :sandbox_export_missing}
    end
  end

  defp walk(root, relative, exclude, files) do
    Enum.reduce_while(File.ls!(Path.join(root, relative)), {:ok, files}, fn name, {:ok, acc} ->
      path = if relative == "", do: name, else: relative <> "/" <> name
      result = inspect_path(root, path, exclude, acc)

      case result do
        {:ok, _} -> {:cont, result}
        _ -> {:halt, result}
      end
    end)
  end

  defp inspect_path(root, path, exclude, files) do
    if exclude.(path) do
      {:ok, files}
    else
      case File.lstat!(Path.join(root, path)) do
        %{type: :directory} -> walk(root, path, exclude, files)
        %{type: :regular, size: size} -> hash_entry(root, path, size, files)
        _ -> {:error, {:sandbox_unsupported_file, path}}
      end
    end
  end

  defp hash_entry(root, path, size, {files, remaining}) when size <= remaining do
    digest =
      Path.join(root, path)
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, {Map.put(files, path, digest), remaining - size}}
  end

  defp hash_entry(_root, _path, _size, _state), do: {:error, :sandbox_source_size_limit}

  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute and not String.contains?(path, ["\n", "\r", <<0>>])
  defp canonical?(path), do: absolute?(path) and PathSafety.canonicalize(path) == {:ok, path}
  defp under?(path, root), do: Path.expand(path) == Path.expand(root) or String.starts_with?(Path.expand(path), Path.expand(root) <> "/")
end
