defmodule SymphonyChecks.Formatter do
  @moduledoc false
  use GenServer

  def init(_opts) do
    path = System.fetch_env!("SYMPHONY_CHECK_REPORT")
    identity = path_identity()
    {:ok, file} = File.open(path, [:write, :exclusive, :binary])
    counts = %{total: 0, passed: 0, failed: 0, skipped: 0, excluded: 0, invalid: 0}
    {:ok, %{file: file, identity: identity, sequence: 0, counts: counts}}
  end

  def handle_cast({:suite_started, _opts}, state) do
    {:noreply, emit(state, %{event: "suite_started"})}
  end

  def handle_cast({:test_finished, test}, state) do
    {status, failures} = test_state(test.state)
    counts = state.counts |> Map.update!(:total, &(&1 + 1)) |> Map.update!(status, &(&1 + 1))

    event = %{
      event: "test_finished",
      test_id: inspect(test.module) <> ":" <> Atom.to_string(test.name),
      state: Atom.to_string(status),
      failures: failures,
      reason: skip_reason(test.state)
    }

    {:noreply, emit(%{state | counts: counts}, event)}
  end

  def handle_cast({:module_finished, %{state: {:failed, failures}}}, state) do
    {:noreply, emit(state, %{event: "module_failed", failures: failure_types(failures)})}
  end

  def handle_cast({:suite_finished, _times}, state) do
    state = emit(state, %{event: "suite_finished", counts: state.counts})
    :ok = :file.sync(state.file)
    :ok = File.close(state.file)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp path_identity do
    System.fetch_env!("SYMPHONY_CHECK_IDENTITY") |> :json.decode()
  end

  defp emit(state, event) do
    record = Map.merge(event, %{identity: state.identity, sequence: state.sequence})
    :ok = IO.binwrite(state.file, [:json.encode(record), "\n"])
    %{state | sequence: state.sequence + 1}
  end

  defp test_state(nil), do: {:passed, []}
  defp test_state({:failed, failures}), do: {:failed, failure_types(failures)}
  defp test_state({:skipped, _}), do: {:skipped, []}
  defp test_state({:excluded, _}), do: {:excluded, []}
  defp test_state({:invalid, _}), do: {:invalid, []}

  defp skip_reason({state, reason}) when state in [:skipped, :excluded], do: inspect(reason)
  defp skip_reason(_), do: nil

  defp failure_types(failures) do
    Enum.map(failures, fn {kind, reason, _stack} ->
      type = if is_exception(reason), do: inspect(reason.__struct__), else: inspect(reason)
      %{kind: Atom.to_string(kind), type: type}
    end)
  end
end
