defmodule SymphonyElixir.Watchdog do
  @moduledoc """
  Host-local process watchdog. The escript's `--watchdog` entrypoint runs outside
  the Symphony application. Every mutating operation is serialized by `flock`.
  """

  @ack "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @commands ~w(run start pause resume recover status)

  @spec main([String.t()]) :: no_return()
  def main([command, config_path]) when command in @commands do
    case load_config(config_path) do
      {:ok, config} ->
        if command == "run" do
          loop(config)
        else
          case locked(config, command) do
            {:ok, state} ->
              IO.puts(Jason.encode!(state))
              System.halt(0)

            {:error, reason} ->
              IO.puts(:stderr, "watchdog: #{reason}")
              System.halt(1)
          end
        end

      {:error, reason} ->
        IO.puts(:stderr, "watchdog: #{reason}")
        System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "Usage: symphony --watchdog run|start|pause|resume|recover|status CONFIG.json")
    System.halt(1)
  end

  @spec once(String.t(), String.t()) :: no_return()
  def once(command, config_path) do
    result =
      if System.get_env("SYMPHONY_WATCHDOG_INTERNAL") == "1" do
        with {:ok, config} <- load_config(config_path), do: step(config, command)
      else
        {:error, "internal entrypoint requires the service lock"}
      end

    case result do
      {:ok, state} ->
        IO.puts(Jason.encode!(state))
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "watchdog: #{reason}")
        System.halt(1)
    end
  end

  @spec load_config(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_config(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, config} <- Jason.decode(raw),
         true <- is_map(config),
         :ok <- validate_config(config) do
      {:ok, Map.put(config, "config_path", Path.expand(path))}
    else
      _ -> {:error, "invalid or unreadable watchdog config"}
    end
  end

  defp validate_config(config) do
    paths = ~w(controller pointer_file state_dir status_file maintenance_file workflow credential_file logs_root)
    numbers = ~w(interval_ms backoff_ms max_attempts stable_ms)

    if Enum.all?(paths, fn key -> absolute_path?(config[key]) end) and
         Enum.all?(numbers, fn key -> is_integer(config[key]) and config[key] > 0 end) and
         (is_nil(config["port"]) or (is_integer(config["port"]) and config["port"] in 1..65_535)) do
      :ok
    else
      {:error, "invalid config fields"}
    end
  end

  defp absolute_path?(value), do: is_binary(value) and Path.type(value) == :absolute and not String.contains?(value, <<0>>)

  defp loop(config) do
    case locked(config, "check") do
      {:ok, _} -> :ok
      {:error, reason} -> IO.puts(:stderr, "watchdog: #{reason}")
    end

    Process.sleep(config["interval_ms"])
    loop(config)
  end

  defp locked(config, command) do
    with :ok <- File.mkdir_p(config["state_dir"]),
         true <- File.regular?(config["controller"]),
         {output, 0} <-
           System.cmd("flock", ["-x", "--close", lock_path(config), config["controller"], "--watchdog-once", command, config["config_path"]],
             stderr_to_stdout: true,
             env: [{"SYMPHONY_WATCHDOG_INTERNAL", "1"}]
           ),
         {:ok, state} <- Jason.decode(String.trim(output)) do
      {:ok, state}
    else
      false -> {:error, "controller executable missing"}
      {output, _} -> {:error, String.trim(output)}
      _ -> {:error, "lock or child command failed"}
    end
  end

  @spec step(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def step(config, command) do
    with :ok <- File.mkdir_p(config["state_dir"]),
         :ok <- File.mkdir_p(Path.dirname(config["status_file"])),
         {:ok, state} <- read_state(config),
         {:ok, pointer} <- read_pointer(config) do
      now = System.system_time(:millisecond)
      state = Map.put(state, "pointer", pointer)

      case command do
        "status" -> {:ok, state}
        "pause" -> maintenance(config, state, now, true)
        "resume" -> maintenance(config, state, now, false)
        "recover" -> recover(config, state, pointer, now)
        "start" -> check(config, state, pointer, now)
        "check" -> check(config, state, pointer, now)
        _ -> {:error, "unknown watchdog operation"}
      end
    end
  end

  defp default_state do
    %{"paused" => false, "versions" => %{}, "process" => nil, "observed" => nil, "pointer" => nil, "phase" => "new", "last_action" => nil, "history_count" => 0}
  end

  defp read_state(config) do
    with {:ok, locked?} <- maintenance_state(config) do
      read_state_file(config, locked?)
    end
  end

  defp maintenance_state(config) do
    case File.lstat(config["maintenance_file"]) do
      {:ok, _} -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      _ -> {:error, "maintenance lock cannot be verified"}
    end
  end

  defp read_state_file(config, locked?) do
    case File.read(state_path(config)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, state} when is_map(state) ->
            if valid_state?(state, config) do
              {:ok, Map.put(state, "paused", state["paused"] or locked?)}
            else
              {:error, "invalid watchdog state; refusing to reset budget"}
            end

          _ ->
            {:error, "invalid watchdog state; refusing to reset budget"}
        end

      {:error, :enoent} ->
        {:ok, default_state() |> Map.put("service", config["workflow"]) |> Map.put("paused", locked?)}

      {:error, _} ->
        {:error, "watchdog state unreadable"}
    end
  end

  defp maintenance(config, state, now, paused) do
    file = config["maintenance_file"]

    result =
      if paused do
        with :ok <- File.mkdir_p(Path.dirname(file)),
             :ok <- File.write(file, "paused\n"),
             do: File.chmod(file, 0o600)
      else
        case File.rm(file) do
          {:error, :enoent} -> :ok
          other -> other
        end
      end

    if result == :ok do
      action = if paused, do: "pause", else: "resume"
      update(config, state, now, action, "maintenance #{action}d", %{"paused" => paused, "phase" => if(paused, do: "paused", else: "recovered")})
    else
      {:error, "cannot update maintenance lock"}
    end
  end

  defp valid_state?(state, config) do
    state["service"] == config["workflow"] and is_boolean(state["paused"]) and
      is_map(state["versions"]) and is_integer(state["history_count"]) and state["history_count"] >= 0 and
      (is_nil(state["process"]) or valid_record?(state["process"])) and
      Enum.all?(state["versions"], fn {version, value} ->
        is_binary(version) and is_map(value) and is_integer(value["attempts"]) and value["attempts"] >= 0 and
          is_integer(value["next_at"]) and value["next_at"] >= 0 and is_boolean(value["awaiting_human"])
      end)
  end

  defp valid_record?(record) do
    is_map(record) and is_integer(record["pid"]) and record["pid"] > 0 and
      is_binary(record["boot_id"]) and is_binary(record["start_ticks"]) and
      is_list(record["cmdline"]) and Enum.all?(record["cmdline"], &is_binary/1) and
      is_binary(record["workflow"]) and is_binary(record["install"]) and
      is_binary(record["version"]) and is_integer(record["seen_at"])
  end

  defp read_pointer(config) do
    case File.read(config["pointer_file"]) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"version" => version, "install" => install}} when is_binary(version) and is_binary(install) ->
            if String.match?(version, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/) and absolute_path?(install) and
                 Path.basename(install) == version and File.dir?(install) and File.regular?(Path.join(install, "bin/symphony")) and
                 File.regular?(config["workflow"]) and fixed_install?(install) do
              {:ok, %{"version" => version, "install" => install}}
            else
              {:ok, %{"error" => "invalid pointer or fixed install"}}
            end

          _ ->
            {:ok, %{"error" => "invalid pointer format"}}
        end

      {:error, _} ->
        {:ok, %{"error" => "pointer missing or unreadable"}}
    end
  end

  defp fixed_install?(install) do
    executable = Path.join(install, "bin/symphony")

    match?({:ok, ^install}, SymphonyElixir.PathSafety.canonicalize(install)) and
      match?({:ok, ^executable}, SymphonyElixir.PathSafety.canonicalize(executable))
  end

  defp recover(config, state, %{"version" => version}, now) do
    versions =
      Map.update(state["versions"], version, budget(), fn old ->
        Map.merge(old, %{"attempts" => 0, "next_at" => 0, "awaiting_human" => false})
      end)

    update(config, state, now, "recover", "new budget round for #{version}", %{"versions" => versions, "phase" => "recovered"})
  end

  defp recover(config, state, _pointer, now), do: update(config, state, now, "blocked", "cannot recover invalid pointer", %{"phase" => "blocked"})

  defp budget, do: %{"attempts" => 0, "next_at" => 0, "awaiting_human" => false}

  defp check(config, state, pointer, now) do
    case observe(config, state) do
      {:alive, process} ->
        alive(config, state, pointer, process, now)

      {:blocked, reason} ->
        update(config, state, now, "blocked", reason, %{"phase" => "blocked"})

      :absent ->
        absent(config, state, pointer, now)
    end
  end

  defp alive(config, state, pointer, process, now) do
    version = process["version"]
    old = Map.get(state["versions"], version, budget())
    stable? = not old["awaiting_human"] and old["attempts"] > 0 and now - process["seen_at"] >= config["stable_ms"]
    versions = if stable?, do: Map.put(state["versions"], version, budget()), else: state["versions"]
    reason = if stable?, do: "process continuously present; round reset", else: "runner present"
    update(config, state, now, "check", reason, %{"observed" => process, "process" => process, "versions" => versions, "phase" => "running", "pointer" => pointer})
  end

  defp absent(config, state, pointer, now) do
    state =
      if state["process"] do
        {:ok, updated} = update(config, state, now, "exit", "recorded runner no longer exists", %{"process" => nil, "phase" => "exited"})
        %{updated | "observed" => nil}
      else
        state
      end

    version = pointer["version"]
    old = if version, do: Map.get(state["versions"], version, budget()), else: budget()

    cond do
      state["paused"] ->
        update(config, state, now, "blocked", "maintenance paused", %{"phase" => "paused"})

      pointer["error"] ->
        update(config, state, now, "blocked", pointer["error"], %{"phase" => "blocked"})

      old["awaiting_human"] or old["attempts"] >= config["max_attempts"] ->
        versions = Map.put(state["versions"], version, Map.put(old, "awaiting_human", true))
        update(config, state, now, "abandon", "version budget exhausted", %{"versions" => versions, "phase" => "awaiting_human"})

      now < old["next_at"] ->
        update(config, state, now, "blocked", "backoff", %{"phase" => "backoff"})

      port_busy?(config["port"]) ->
        update(config, state, now, "blocked", "status port occupied by unknown process", %{"phase" => "blocked"})

      true ->
        launch(config, state, pointer, old, now)
    end
  end

  defp launch(config, state, pointer, old, now) do
    case credential(config) do
      {:error, reason} ->
        update(config, state, now, "blocked", reason, %{"phase" => "blocked"})

      {:ok, token} ->
        version = pointer["version"]
        next = %{"attempts" => old["attempts"] + 1, "next_at" => now + config["backoff_ms"], "awaiting_human" => false}
        state = %{state | "versions" => Map.put(state["versions"], version, next)}
        {:ok, state} = update(config, state, now, "attempt", "launch #{version}", %{"phase" => "starting"})

        case spawn_runner(config, pointer, token, now) do
          {:ok, process} -> update(config, state, now, "launch", "runner started", %{"process" => process, "observed" => process, "phase" => "running"})
          {:error, reason} -> update(config, state, now, "launch_failed", reason, %{"phase" => "backoff"})
        end
    end
  end

  defp credential(config) do
    path = config["credential_file"]

    with {:ok, info} <- File.stat(path),
         true <-
           info.type == :regular and Bitwise.band(info.mode, 0o077) == 0 and
             Bitwise.band(info.mode, 0o400) != 0 and info.uid == current_uid(),
         {:ok, raw} <- File.read(path),
         token when is_binary(token) and byte_size(token) > 0 <- String.trim(raw) do
      {:ok, token}
    else
      _ -> {:error, "credential file missing, unreadable or permissions unsafe"}
    end
  end

  defp current_uid, do: File.stat!("/proc/self").uid

  defp spawn_runner(config, pointer, token, now) do
    executable = Path.join(pointer["install"], "bin/symphony")
    args = [@ack, "--logs-root", config["logs_root"], config["workflow"]]
    log = Path.join(config["state_dir"], "runner.log")

    script =
      "umask 077; setsid " <>
        Enum.map_join([executable | args], " ", &quote_shell/1) <>
        " >> " <> quote_shell(log) <> " 2>&1 </dev/null & echo $!"

    case System.cmd("sh", ["-c", script], env: [{"GITHUB_TOKEN", token}, {"SYMPHONY_WATCHDOG_INTERNAL", nil}], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pid, ""} ->
            case await_identity(pid, config["workflow"], executable, 100) do
              {:ok, identity} ->
                {:ok, Map.merge(identity, %{"version" => pointer["version"], "install" => pointer["install"], "workflow" => config["workflow"], "seen_at" => now})}

              _ ->
                {:error, "started process exited before identity recording"}
            end

          _ ->
            {:error, "launcher returned no process id"}
        end

      _ ->
        {:error, "launcher failed"}
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp await_identity(pid, workflow, executable, remaining) do
    case process_identity(pid) do
      {:ok, identity} ->
        if matching_command?(identity["cmdline"], workflow, executable) do
          {:ok, identity}
        else
          retry_identity(pid, workflow, executable, remaining)
        end

      _ ->
        retry_identity(pid, workflow, executable, remaining)
    end
  end

  defp retry_identity(_pid, _workflow, _executable, 0), do: {:error, :unverifiable}

  defp retry_identity(pid, workflow, executable, remaining) do
    Process.sleep(20)
    await_identity(pid, workflow, executable, remaining - 1)
  end

  defp observe(config, state) do
    recorded = state["process"]

    case recorded do
      %{"pid" => pid} ->
        case process_identity(pid) do
          {:ok, current} ->
            if same_process?(current, recorded, config) do
              {:alive, recorded}
            else
              {:blocked, "recorded process identity conflict"}
            end

          {:error, :absent} ->
            scan_unrecorded(config)

          {:error, _} ->
            {:blocked, "recorded process identity cannot be verified"}
        end

      _ ->
        scan_unrecorded(config)
    end
  end

  defp same_process?(current, recorded, config) do
    current["boot_id"] == recorded["boot_id"] and current["start_ticks"] == recorded["start_ticks"] and
      current["cmdline"] == recorded["cmdline"] and recorded["workflow"] == config["workflow"] and
      matching_command?(current["cmdline"], config["workflow"], Path.join(recorded["install"], "bin/symphony"))
  end

  defp scan_unrecorded(config) do
    case File.ls("/proc") do
      {:ok, entries} ->
        result =
          Enum.reduce_while(entries, :absent, fn entry, previous ->
            case Integer.parse(entry) do
              {pid, ""} ->
                case File.read("/proc/#{pid}/cmdline") do
                  {:ok, raw} ->
                    if String.contains?(raw, config["workflow"]) and String.contains?(raw, "symphony") do
                      {:halt, {:blocked, "unrecorded runner-like process #{pid}"}}
                    else
                      {:cont, previous}
                    end

                  {:error, :eacces} ->
                    {:cont, {:blocked, "process table identity inaccessible"}}

                  {:error, :eperm} ->
                    {:cont, {:blocked, "process table identity inaccessible"}}

                  _ ->
                    {:cont, previous}
                end

              _ ->
                {:cont, previous}
            end
          end)

        result

      _ ->
        {:blocked, "cannot scan process table"}
    end
  end

  defp process_identity(pid) do
    with {:ok, before} <- File.read("/proc/#{pid}/stat"),
         {:ok, command} <- File.read("/proc/#{pid}/cmdline"),
         {:ok, after_read} <- File.read("/proc/#{pid}/stat"),
         {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         {:ok, ticks} <- stat_start_ticks(before),
         {:ok, ^ticks} <- stat_start_ticks(after_read) do
      {:ok, %{"pid" => pid, "boot_id" => String.trim(boot), "start_ticks" => ticks, "cmdline" => String.split(command, <<0>>, trim: true)}}
    else
      {:error, :enoent} -> {:error, :absent}
      {:error, :absent} -> {:error, :absent}
      _ -> {:error, :unverifiable}
    end
  end

  defp stat_start_ticks(raw) do
    case Regex.run(~r/^\d+ \(.*\) (.*)$/s, raw) do
      [_, tail] ->
        fields = String.split(tail)

        case {Enum.at(fields, 0), Enum.at(fields, 19)} do
          {"Z", _} -> {:error, :absent}
          {_, ticks} when is_binary(ticks) -> {:ok, ticks}
          _ -> {:error, :unverifiable}
        end

      _ ->
        {:error, :unverifiable}
    end
  end

  defp matching_command?(args, workflow, executable) do
    is_list(args) and workflow in args and executable in args and @ack in args
  end

  defp port_busy?(nil), do: false

  defp port_busy?(port) do
    hex = port |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.upcase()

    Enum.any?(["/proc/net/tcp", "/proc/net/tcp6"], fn path ->
      case File.read(path) do
        {:ok, table} -> String.match?(table, ~r/:#{hex}\s+[0-9A-F:]+\s+0A\s/)
        _ -> true
      end
    end)
  end

  defp update(config, state, now, action, reason, changes) do
    state = state |> Map.merge(changes) |> Map.put("last_action", %{"at" => now, "action" => action, "reason" => reason})
    evidence = %{"at" => now, "action" => action, "reason" => reason, "pointer" => state["pointer"], "observed" => state["observed"], "phase" => state["phase"]}
    state = Map.update(state, "history_count", 1, &(&1 + 1))
    tmp = state_path(config) <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(audit_path(config), Jason.encode!(evidence) <> "\n", [:append]),
         :ok <- File.chmod(audit_path(config), 0o600),
         :ok <- File.write(tmp, Jason.encode!(state)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, state_path(config)) do
      {:ok, state}
    else
      _ -> {:error, "cannot persist watchdog evidence"}
    end
  end

  defp state_path(config), do: config["status_file"]
  defp audit_path(config), do: Path.join(config["state_dir"], "history.jsonl")
  defp lock_path(config), do: Path.join(config["state_dir"], "start.lock")
end
