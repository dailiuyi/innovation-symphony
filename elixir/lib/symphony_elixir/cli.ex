defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile
  alias SymphonyElixir.Mvp.Preflight

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, preflight: :boolean, logs_root: :string, port: :integer]
  @watchdog_commands ~w(run start pause resume recover status)

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          :file_regular? => (String.t() -> boolean()),
          :set_workflow_file_path => (String.t() -> :ok | {:error, term()}),
          :set_logs_root => (String.t() -> :ok | {:error, term()}),
          :set_server_port_override => (non_neg_integer() | nil -> :ok | {:error, term()}),
          :ensure_all_started => (-> ensure_started_result()),
          optional(:preflight) => (String.t() -> {:ok, map()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(["--watchdog" | args]), do: System.halt(watchdog_main(args))
  def main(["--watchdog-once", command, path]), do: System.halt(watchdog_once(command, path))
  def main(["--watchdog-once", "block", path, reason]), do: System.halt(watchdog_block_once(path, reason))

  def main(args) do
    main(args, fn -> Application.ensure_all_started(:symphony_elixir) end)
  end

  defp watchdog_main([command, config_path]) when command in @watchdog_commands do
    case SymphonyElixir.Watchdog.load_config(config_path) do
      {:ok, config} when command == "run" -> watchdog_loop(config)
      {:ok, config} -> watchdog_finish(watchdog_locked(config, command))
      error -> watchdog_finish(error)
    end
  end

  defp watchdog_main(_args) do
    IO.puts(
      :stderr,
      "Usage: symphony --watchdog run|start|pause|resume|recover|status CONFIG.json"
    )

    1
  end

  defp watchdog_once(command, config_path) do
    result =
      case SymphonyElixir.Watchdog.load_config(config_path) do
        {:ok, config} ->
          with true <- service_lock_held?(config),
               :ok <- SymphonyElixir.Watchdog.bind_state_dir(config) do
            SymphonyElixir.Watchdog.step(config, command)
          else
            false -> {:error, "internal entrypoint requires the service lock"}
            error -> error
          end

        error ->
          error
      end

    watchdog_finish(result)
  end

  defp watchdog_block_once(config_path, reason) do
    result =
      case SymphonyElixir.Watchdog.load_config(config_path) do
        {:ok, config} ->
          with true <- service_lock_held?(config),
               :ok <- SymphonyElixir.Watchdog.bind_state_dir(config) do
            SymphonyElixir.Watchdog.record_block(config, reason)
          else
            false -> {:error, "internal entrypoint requires the service lock"}
            error -> error
          end

        error ->
          error
      end

    watchdog_finish(result)
  end

  defp watchdog_finish(result) do
    case result do
      {:ok, state} ->
        IO.puts(Jason.encode!(state))
        0

      {:error, reason} ->
        IO.puts(:stderr, "watchdog: #{reason}")
        1
    end
  end

  # GNU flock keeps its locked descriptor open in the command by default. A
  # caller-supplied environment variable is not proof of ownership of that lock.
  defp service_lock_held?(config) do
    lock_path = SymphonyElixir.Watchdog.service_lock_path(config)

    case File.ls("/proc/self/fd") do
      {:ok, descriptors} -> Enum.any?(descriptors, &service_lock_descriptor?(&1, lock_path))
      _ -> false
    end
  end

  defp service_lock_descriptor?(descriptor, lock_path) do
    fd = Path.join("/proc/self/fd", descriptor)

    case File.read_link(fd) do
      {:ok, ^lock_path} -> service_lock_info?(descriptor)
      _ -> false
    end
  end

  defp service_lock_info?(descriptor) do
    case File.read(Path.join("/proc/self/fdinfo", descriptor)) do
      {:ok, info} -> String.match?(info, ~r/^lock:\s+\d+: FLOCK\s+ADVISORY\s+WRITE\s/m)
      _ -> false
    end
  end

  defp watchdog_loop(config) do
    watchdog_loop(config, System.monotonic_time(:millisecond))
  end

  defp watchdog_loop(config, due_at) do
    case watchdog_locked(config, "check") do
      {:ok, _} -> :ok
      {:error, reason} -> IO.puts(:stderr, "watchdog: #{reason}")
    end

    next_at = due_at + config["interval_ms"]
    now = System.monotonic_time(:millisecond)
    Process.sleep(max(next_at - now, 0))
    watchdog_loop(config, max(next_at, now))
  end

  defp watchdog_locked(config, command) do
    result =
      with true <- File.regular?(config["controller"]),
           {output, 0} <-
             System.cmd(
               "flock",
               [
                 "-x",
                 SymphonyElixir.Watchdog.service_lock_path(config),
                 config["controller"],
                 "--watchdog-once",
                 command,
                 config["config_path"]
               ],
               stderr_to_stdout: true
             ),
           {:ok, state} when is_map(state) <- Jason.decode(String.trim(output)),
           true <- SymphonyElixir.Watchdog.valid_response?(state, config) do
        {:ok, state}
      else
        false ->
          if File.regular?(config["controller"]),
            do: {:error, "invalid watchdog child response"},
            else: {:error, "controller executable missing"}

        {:error, %Jason.DecodeError{}} ->
          {:error, "invalid watchdog child response"}

        {:error, reason} ->
          {:error, "watchdog lock or child failed: #{inspect(reason)}"}

        {:ok, _} ->
          {:error, "invalid watchdog child response"}

        {"watchdog: workflow state directory binding conflict\n", 1} ->
          {:error, "workflow state directory binding conflict"}

        {"watchdog: workflow state directory binding unreadable\n", 1} ->
          {:error, "workflow state directory binding unreadable"}

        {_output, status} ->
          {:error, "watchdog child failed with exit #{status}"}
      end

    case result do
      {:error, reason} ->
        report_block(config, reason)
        result

      _ ->
        result
    end
  end

  defp report_block(config, reason) do
    self = :escript.script_name() |> to_string()

    if File.regular?(self) do
      System.cmd("flock", ["-x", SymphonyElixir.Watchdog.service_lock_path(config), self, "--watchdog-once", "block", config["config_path"], reason], stderr_to_stdout: true)
    end
  end

  @doc false
  @spec main([String.t()], (-> ensure_started_result())) :: no_return()
  def main(args, ensure_all_started) do
    deps = Map.put(runtime_deps(ensure_all_started), :preflight, &preflight_with_stderr_logging/1)

    case evaluate(args, deps) do
      :ok ->
        wait_for_shutdown()

      {:ok, report} ->
        IO.puts(Jason.encode!(report))
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  # Only the exiting CLI preflight process changes its logger. Configure it before
  # starting query dependencies so retries cannot contaminate the JSON on stdout.
  defp preflight_with_stderr_logging(path) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.flush()
    :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_error},
        # Match Elixir's handler filters; OTP's defaults drop Elixir-domain logs.
        filters: [remote_gl: {&:logger_filters.remote_gl/2, :stop}],
        filter_default: :log,
        formatter: Logger.default_formatter()
      })

    try do
      Preflight.run(path)
    after
      Logger.flush()
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, map()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        evaluate_workflow(opts, Path.expand("WORKFLOW.md"), deps)

      {opts, [workflow_path], []} ->
        evaluate_workflow(opts, workflow_path, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_workflow(opts, path, deps) do
    with :ok <- require_guardrails_acknowledgement(opts) do
      run_mode(opts, path, deps)
    end
  end

  defp run_mode(opts, path, deps) do
    if Keyword.get(opts, :preflight, false) do
      run_preflight(opts, path, deps)
    else
      with :ok <- maybe_set_logs_root(opts, deps),
           :ok <- maybe_set_server_port(opts, deps) do
        run(path, deps)
      end
    end
  end

  defp run_preflight(opts, path, deps) do
    if Keyword.has_key?(opts, :logs_root) or Keyword.has_key?(opts, :port) do
      {:error, "--preflight cannot be combined with --logs-root or --port"}
    else
      preflight = Map.get(deps, :preflight, &Preflight.run/1)

      case preflight.(Path.expand(path)) do
        {:ok, report} -> {:ok, report}
        {:error, reason} -> {:error, "Preflight failed: #{inspect(reason)}"}
      end
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--preflight | --logs-root <path> --port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: ensure_all_started
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
