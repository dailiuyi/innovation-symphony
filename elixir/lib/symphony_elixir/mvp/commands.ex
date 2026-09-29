defmodule SymphonyElixir.Mvp.Commands do
  @moduledoc "Controller-owned commands for trusted repositories on Linux/WSL."

  alias SymphonyElixir.Tracker

  @spec run([String.t()], Path.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(argv, cwd, timeout_ms, opts \\ []) do
    case execute(argv, cwd, timeout_ms, opts, "") do
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
      {:ok, {_stream, status}} -> {:ok, status}
      error -> error
    end
  end

  defp execute([executable | arguments], cwd, timeout_ms, opts, output) do
    env = clean_env() ++ Keyword.get(opts, :env, [])

    case System.find_executable("timeout") do
      nil ->
        {:error, :mvp_requires_gnu_timeout}

      timeout ->
        seconds = Integer.to_string(max(1, div(timeout_ms + 999, 1_000))) <> "s"

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
    hooks = Path.join(System.tmp_dir!(), "innovation-symphony-empty-hooks")
    File.mkdir_p!(hooks)

    run(
      ["git", "-c", "core.hooksPath=#{hooks}", "-c", "credential.helper=", "-c", "user.name=Symphony", "-c", "user.email=symphony@localhost" | arguments],
      cwd,
      120_000,
      opts
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

  @spec clean_env() :: [{String.t(), String.t() | nil}]
  def clean_env do
    names = Tracker.bind_agent_tools().secret_environment_names

    (names ++ ["GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_ASKPASS", "SSH_ASKPASS"])
    |> Enum.uniq()
    |> Enum.map(&{&1, nil})
    |> Kernel.++([{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}])
  end
end
