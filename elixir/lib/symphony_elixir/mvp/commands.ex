defmodule SymphonyElixir.Mvp.Commands do
  @moduledoc "Controller-owned commands for trusted repositories on Linux/WSL."

  alias SymphonyElixir.Tracker

  @git_fetch_deadline_key {__MODULE__, :git_fetch_deadline}

  @doc "Scope Git fetches to an absolute wall-clock deadline in the calling process."
  @spec with_git_fetch_deadline(integer(), (-> result)) :: result when result: var
  def with_git_fetch_deadline(deadline_unix_ms, fun) when is_integer(deadline_unix_ms) and is_function(fun, 0) do
    previous = Process.put(@git_fetch_deadline_key, deadline_unix_ms)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@git_fetch_deadline_key), else: Process.put(@git_fetch_deadline_key, previous)
    end
  end

  @spec run([String.t()], Path.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(argv, cwd, timeout_ms, opts \\ []) do
    run_command(argv, cwd, timeout_ms, opts, :seconds)
  end

  defp run_command(argv, cwd, timeout_ms, opts, precision) do
    case execute(argv, cwd, timeout_ms, opts, "", precision) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:command_failed, status, String.slice(output, -4_000, 4_000)}}
      error -> error
    end
  end

  @doc "Stream complete merged check output to disk, including failed and timed-out commands."
  @spec run_logged([String.t()], Path.t(), pos_integer(), Path.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def run_logged(argv, cwd, timeout_ms, log_path) do
    File.write!(log_path, "")

    case execute(argv, cwd, timeout_ms, [], File.stream!(log_path)) do
      {:ok, {_stream, status}} ->
        # Ubuntu may ship uutils timeout, whose missing-command diagnostic
        # omits the executable. Preserve that identity in terminal check logs.
        if status == 127, do: File.write!(log_path, "\ncommand exited 127: #{List.first(argv)}\n", [:append])
        {:ok, status}

      error ->
        error
    end
  end

  defp execute([executable | arguments], cwd, timeout_ms, opts, output, precision \\ :seconds) do
    cleaned =
      case Keyword.fetch(opts, :secret_environment_names) do
        {:ok, names} -> clean_env(names)
        :error -> clean_env()
      end

    env = cleaned ++ Keyword.get(opts, :env, [])

    case System.find_executable("timeout") do
      nil ->
        {:error, :mvp_requires_gnu_timeout}

      timeout ->
        seconds =
          if precision == :seconds or rem(timeout_ms, 1_000) == 0 do
            Integer.to_string(max(1, div(timeout_ms + 999, 1_000))) <> "s"
          else
            milliseconds = timeout_ms |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
            Integer.to_string(div(timeout_ms, 1_000)) <> "." <> milliseconds <> "s"
          end

        {:ok,
         System.cmd(timeout, ["--kill-after=5s", seconds, executable | arguments],
           cd: cwd,
           env: env,
           stderr_to_stdout: true,
           into: output
         )}
    end
  end

  @spec git([String.t()], Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def git(arguments, cwd, opts \\ []) do
    with {:ok, timeout_ms} <- git_timeout(arguments) do
      run_git(arguments, cwd, timeout_ms, opts)
    end
  end

  defp git_timeout(["fetch" | _]) do
    case Process.get(@git_fetch_deadline_key) do
      nil ->
        {:ok, 120_000}

      deadline ->
        remaining = deadline - System.system_time(:millisecond)
        if remaining > 0, do: {:ok, min(remaining, 1_800_000)}, else: {:error, :mvp_recovery_resource_exhausted}
    end
  end

  defp git_timeout(_arguments), do: {:ok, 120_000}

  defp run_git(arguments, cwd, timeout_ms, opts) do
    hooks = Path.join(System.tmp_dir!(), "innovation-symphony-empty-hooks")
    File.mkdir_p!(hooks)

    run_command(
      ["git", "-c", "core.hooksPath=#{hooks}", "-c", "credential.helper=", "-c", "user.name=Symphony", "-c", "user.email=symphony@localhost" | arguments],
      cwd,
      timeout_ms,
      opts,
      :milliseconds
    )
    |> case do
      {:ok, output} -> {:ok, if(Keyword.get(opts, :preserve_output, false), do: output, else: String.trim(output))}
      {:error, {:command_failed, status, _output}} -> {:error, {:git_failed, List.first(arguments), status}}
      error -> error
    end
  end

  @spec git!([String.t()], Path.t(), keyword()) :: String.t()
  def git!(arguments, cwd, opts \\ []) do
    case git(arguments, cwd, opts) do
      {:ok, output} -> output
      {:error, reason} -> raise "Git command failed: #{inspect(reason)}"
    end
  end

  @spec clean_env([String.t()] | nil) :: [{String.t(), String.t() | nil}]
  def clean_env(names \\ nil) do
    names = if is_nil(names), do: Tracker.bind_agent_tools().secret_environment_names, else: names

    (names ++ ["GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_ASKPASS", "SSH_ASKPASS"])
    |> Enum.uniq()
    |> Enum.map(&{&1, nil})
    |> Kernel.++([{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}])
  end
end
