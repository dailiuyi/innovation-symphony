defmodule SymphonyElixir.Mvp.VmReadiness do
  @moduledoc "Read-only readiness for an explicitly identified VM; never falls back to the host."

  import Bitwise
  alias SymphonyElixir.Mvp.Commands
  alias SymphonyElixir.PathSafety

  @minimum_free_bytes 5 * 1024 * 1024 * 1024
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @keys ~w(capability_probes enabled required_acceptances required_backend vm_uuid)
  @runtime_identity_path Path.expand("../../../../scripts/runtime-identity.json", __DIR__)
  @external_resource @runtime_identity_path
  @native_identity @runtime_identity_path |> File.read!() |> Jason.decode!() |> Map.fetch!("codex")
  @native_version Map.fetch!(@native_identity, "version")
  @native_sha256 Map.fetch!(@native_identity, "linux_binary_sha256")

  @spec settings(map()) :: {:ok, map()} | {:error, atom()}
  def settings(value) do
    uuid = value["vm_uuid"]
    probes = value["capability_probes"]

    if Enum.sort(Map.keys(value)) == @keys and valid_uuid?(uuid) and
         value["required_acceptances"] == [] and valid_probes?(probes) do
      {:ok,
       %{
         enabled: true,
         required_backend: "vm",
         required_acceptances: [],
         vm_uuid: String.downcase(uuid),
         capability_probes: probes
       }}
    else
      {:error, :invalid_execution_readiness}
    end
  end

  defp valid_uuid?(uuid) when is_binary(uuid) do
    Regex.match?(@uuid, uuid) and String.downcase(uuid) not in ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"]
  end

  defp valid_uuid?(_), do: false

  defp valid_probes?(probes) when is_map(probes) and map_size(probes) in 2..16 do
    Enum.all?(~w(admin docker), &Map.has_key?(probes, &1)) and
      Enum.all?(probes, fn {name, argv} ->
        is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, name) and valid_argv?(argv)
      end)
  end

  defp valid_probes?(_), do: false

  defp valid_argv?([binary | arguments]) when is_binary(binary) do
    Path.type(binary) == :absolute and length(arguments) < 64 and
      Enum.all?([binary | arguments], &(is_binary(&1) and byte_size(&1) in 1..4096 and not String.contains?(&1, [<<0>>, "\n", "\r"])))
  end

  defp valid_argv?(_), do: false

  @spec check(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(settings, opts \\ []) do
    with {:ok, hypervisor} <- identity(settings, opts),
         :ok <- capabilities(settings, opts),
         {:ok, directories} <- directories(settings, opts) do
      {:ok,
       %{
         "schema" => 1,
         "status" => "ready",
         "backend" => "vm",
         "vm_uuid" => settings.execution_readiness.vm_uuid,
         "hypervisor" => hypervisor,
         "formal_acceptance" => false,
         "directories" => directories,
         "blockers" => []
       }}
    end
  end

  defp identity(settings, opts) do
    with {:ok, _} <- no_container(settings, opts),
         {:ok, hypervisor} <- command(settings, ["systemd-detect-virt", "--vm"], opts),
         true <- String.trim(hypervisor) not in ["", "none"],
         {:ok, raw_uuid} <- command(settings, ["sudo", "-n", "cat", "/sys/class/dmi/id/product_uuid"], opts),
         actual = raw_uuid |> String.trim() |> String.downcase(),
         true <- valid_uuid?(actual) and actual == settings.execution_readiness.vm_uuid do
      {:ok, String.trim(hypervisor)}
    else
      _ -> {:error, :execution_readiness_vm_identity_mismatch}
    end
  end

  defp no_container(settings, opts) do
    case command(settings, ["systemd-detect-virt", "--container"], opts) do
      {:error, {:command_failed, 1, output}} -> if String.trim(output) == "none", do: {:ok, :none}, else: {:error, :container_detected}
      _ -> {:error, :container_detected}
    end
  end

  defp capabilities(settings, opts) do
    probes = settings.execution_readiness.capability_probes
    names = ~w(admin docker) ++ Enum.sort(Map.keys(probes) -- ~w(admin docker))

    Enum.reduce_while(names, :ok, fn name, :ok ->
      case command(settings, settings.execution_readiness.capability_probes[name], opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, {:execution_readiness_vm_capability, name}}}
      end
    end)
  end

  defp directories(settings, opts) do
    paths = [settings.state_dir, settings.execution_workspace_root, Path.join(Path.dirname(settings.state_dir), "sandboxes")]

    with {:ok, paths} <- canonical_directories(settings, paths),
         true <- disjoint?(paths) do
      probe_directories(settings, paths, opts)
    else
      false -> {:error, :execution_readiness_vm_directory_overlap}
      error -> error
    end
  end

  defp probe_directories(settings, paths, opts) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, reports} ->
      case directory(settings, path, opts) do
        {:ok, report} -> {:cont, {:ok, reports ++ [report]}}
        error -> {:halt, error}
      end
    end)
  end

  defp canonical_directories(settings, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, resolved} ->
      with {:ok, stat} <- File.stat(path),
           true <- stat.type == :directory and stat.access == :read_write and (stat.mode &&& 0o222) != 0 and (stat.mode &&& 0o111) != 0,
           {:ok, canonical} <- PathSafety.canonicalize(path),
           {:ok, _} <- directory_access(settings, canonical) do
        {:cont, {:ok, resolved ++ [canonical]}}
      else
        _ -> {:halt, {:error, {:execution_readiness_vm_directory, path}}}
      end
    end)
  end

  defp directory_access(settings, path) do
    argv = ["/usr/bin/test", "-r", path, "-a", "-w", path, "-a", "-x", path]
    bounded_command(settings, argv, Path.dirname(settings.workflow_path))
  end

  defp disjoint?(paths) do
    Enum.all?(paths, fn left ->
      Enum.all?(List.delete(paths, left), fn right ->
        left != right and not String.starts_with?(left, String.trim_trailing(right, "/") <> "/") and
          not String.starts_with?(right, String.trim_trailing(left, "/") <> "/")
      end)
    end)
  end

  defp directory(settings, path, opts) do
    with {:ok, output} <- command(settings, ["stat", "-f", "-c", "%T %a %S", "--", path], opts),
         [filesystem, blocks, block_size] <- String.split(output),
         true <- filesystem not in ~w(tmpfs ramfs overlayfs overlay aufs squashfs),
         {blocks, ""} when blocks >= 0 <- Integer.parse(blocks),
         {block_size, ""} when block_size > 0 <- Integer.parse(block_size),
         free_bytes = blocks * block_size,
         true <- free_bytes >= @minimum_free_bytes,
         {:ok, options} <- command(settings, ["findmnt", "-n", "-o", "OPTIONS", "--target", path], opts),
         true <- "rw" in String.split(String.trim(options), ",") do
      {:ok, %{"path" => path, "filesystem" => filesystem, "free_bytes" => free_bytes}}
    else
      _ -> {:error, {:execution_readiness_vm_storage, path}}
    end
  end

  @spec native_client(map(), String.t(), keyword()) :: :ok | {:error, atom()}
  def native_client(settings, binary, opts) do
    with executable when is_binary(executable) <- System.find_executable(binary),
         {:ok, canonical} <- PathSafety.canonicalize(executable),
         {:ok, sha256} <- native_digest(canonical),
         true <- sha256 == @native_sha256,
         {:ok, output} <- command(settings, [canonical, "--version"], opts),
         true <- pinned_version?(output) do
      :ok
    else
      false -> {:error, :native_client_mismatch}
      {:error, :not_elf} -> {:error, :native_client_mismatch}
      _ -> {:error, :native_client_unavailable}
    end
  end

  defp pinned_version?(output) do
    output |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "codex-cli")) == ["codex-cli #{@native_version}"]
  end

  defp native_digest(path) do
    case File.open(path, [:read, :binary], &read_native_digest/1) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_native_digest(file) do
    case IO.binread(file, 4) do
      <<127, "ELF">> = header -> digest_stream(file, :crypto.hash_update(:crypto.hash_init(:sha256), header))
      _ -> {:error, :not_elf}
    end
  end

  defp digest_stream(file, hash) do
    case IO.binread(file, 1024 * 1024) do
      :eof -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
      chunk -> digest_stream(file, :crypto.hash_update(hash, chunk))
    end
  end

  defp command(settings, argv, opts) do
    cwd = Path.dirname(settings.workflow_path)

    case Keyword.fetch(opts, :vm_readiness_command_run) do
      {:ok, runner} -> runner.(argv, cwd, 30_000)
      :error -> bounded_command(settings, argv, cwd)
    end
  end

  defp bounded_command(settings, argv, cwd) do
    task =
      Task.async(fn ->
        try do
          Commands.run(argv, cwd, 30_000, secret_environment_names: settings.secret_environment_names)
        rescue
          _ -> {:error, :execution_readiness_vm_probe_failed}
        end
      end)

    case Task.yield(task, 35_000) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :execution_readiness_vm_probe_timeout}
    end
  end
end
