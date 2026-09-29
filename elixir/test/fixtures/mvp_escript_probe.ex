defmodule SymphonyElixir.MvpEscriptProbe do
  @moduledoc false

  def main([workflow_path]) do
    workflow_path = IO.chardata_to_string(workflow_path)
    {:ok, _} = Application.ensure_all_started(:elixir)
    {:ok, _} = Application.ensure_all_started(:crypto)
    _ = Application.load(:symphony_elixir)

    :ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    runtime_lib_dir = :code.lib_dir(:symphony_elixir) |> List.to_string()
    IO.puts("ESCRIPT_RUNTIME_LIB_DIR=#{runtime_lib_dir}")
    IO.puts("MVP_SETTINGS=#{inspect(SymphonyElixir.Config.mvp_settings())}")
    IO.puts("MVP_AVAILABLE=#{inspect(SymphonyElixir.Mvp.available?(ready_issue()))}")
  end

  defp ready_issue do
    %SymphonyElixir.Tracker.Issue{
      id: "probe-12",
      native_ref: %{"repo" => "owner/repo", "number" => 12},
      state: "open",
      labels: ["ready"],
      dispatchable: true
    }
  end
end
