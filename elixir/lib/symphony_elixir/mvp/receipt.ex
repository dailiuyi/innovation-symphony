defmodule SymphonyElixir.Mvp.Receipt do
  @moduledoc "Durable at-most-once admission receipts for the opt-in GitHub MVP."

  @spec path(map(), map()) :: Path.t()
  def path(settings, issue) do
    repo = issue.native_ref["repo"]
    key = :crypto.hash(:sha256, "#{repo}:#{issue.id}") |> Base.encode16(case: :lower)
    Path.join(settings.state_dir, key <> ".json")
  end

  @spec exists?(map(), map()) :: boolean()
  def exists?(settings, issue), do: File.exists?(path(settings, issue))

  @spec claim(map(), map()) :: {:ok, Path.t()} | {:error, term()}
  def claim(settings, issue) do
    File.mkdir_p!(settings.state_dir)
    file = path(settings, issue)

    case File.open(file, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        data = %{
          "schema" => 1,
          "repository" => issue.native_ref["repo"],
          "issue" => issue.id,
          "status" => "claimed",
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        try do
          IO.binwrite(device, Jason.encode!(data))
          :file.sync(device)
        after
          File.close(device)
        end

        {:ok, file}

      {:error, :eexist} ->
        {:error, :mvp_receipt_exists}

      {:error, reason} ->
        {:error, {:mvp_receipt_write, reason}}
    end
  end

  @spec read(Path.t()) :: map()
  def read(file), do: file |> File.read!() |> Jason.decode!()

  @spec update(Path.t(), String.t(), map()) :: :ok
  def update(file, status, fields \\ %{}) do
    data =
      read(file)
      |> Map.merge(fields)
      |> Map.put("status", status)
      |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now()))

    temporary = file <> ".next"
    File.write!(temporary, Jason.encode!(data, pretty: true), [:sync])
    File.rename!(temporary, file)
    :ok
  end
end
