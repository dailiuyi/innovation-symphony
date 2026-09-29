defmodule SymphonyElixir.PreflightGitHubPlug do
  @moduledoc false

  def init(responses), do: responses

  # Loaded only by the packaged preflight regression test through Req's plug adapter.
  def call(conn, responses) do
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
    page = String.to_integer(page)
    attempt = Process.get(:preflight_request_count, 0)
    Process.put(:preflight_request_count, attempt + 1)
    IO.puts(:stderr, "preflight-request page=#{page}")
    {^page, response} = Enum.fetch!(responses, attempt)

    case response do
      {:transport_error, reason} ->
        Req.Test.transport_error(conn, reason)

      {status, body} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end
end
