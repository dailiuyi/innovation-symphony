defmodule SymphonyElixir.PreflightGitHubPlug do
  @moduledoc false

  def init(pages), do: pages

  # Loaded only by the packaged preflight regression test through Req's plug adapter.
  def call(conn, pages) do
    for name <- [
          SymphonyElixir.Supervisor,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.AgentRuntimeSupervisor,
          SymphonyElixir.TaskSupervisor,
          SymphonyElixir.Orchestrator
        ] do
      nil = Process.whereis(name)
    end

    "GET" = conn.method
    "/repos/owner/repo/issues" = conn.request_path
    %{"state" => "open", "per_page" => "100", "page" => page} = conn.query_params
    {:ok, "", conn} = Plug.Conn.read_body(conn)
    body = pages |> Map.fetch!(String.to_integer(page)) |> Jason.encode!()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end
end
