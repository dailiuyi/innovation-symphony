defmodule SymphonyElixir.Mvp.Commands do
  @moduledoc "Controller-owned commands for trusted repositories on Linux/WSL."

  alias SymphonyElixir.Tracker

  @spec run([String.t()], Path.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run([executable | arguments], cwd, timeout_ms, opts \\ []) do
    env = clean_env() ++ Keyword.get(opts, :env, [])

    case System.find_executable("timeout") do
      nil ->
        {:error, :mvp_requires_gnu_timeout}

      timeout ->
        seconds = Integer.to_string(max(1, div(timeout_ms + 999, 1_000))) <> "s"

        case System.cmd(timeout, ["--kill-after=5s", seconds, executable | arguments],
               cd: cwd,
               env: env,
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:command_failed, status, String.slice(output, -4_000, 4_000)}}
        end
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
      {:ok, output} -> {:ok, String.trim(output)}
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
