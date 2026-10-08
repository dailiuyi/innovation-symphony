defmodule SymphonyElixir.Mvp.ModelSettingsServer do
  @moduledoc "Opt-in loopback-only administrator endpoint, separate from execution and observability."
  import Plug.Conn
  alias SymphonyElixir.Mvp.{ModelServices, ModelSettings}

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(path) do
    with {:ok, config} <- ModelSettings.load(path),
         {:ok, _} <- admin_key(config) do
      Bandit.start_link(plug: {__MODULE__, path}, ip: {127, 0, 0, 1}, port: config["port"])
    end
  end

  @spec init(Path.t()) :: Path.t()
  def init(path), do: path

  @spec call(Plug.Conn.t(), Path.t()) :: Plug.Conn.t()
  def call(conn, path) do
    with {:ok, config} <- ModelSettings.load(path),
         {:ok, key} <- admin_key(config),
         ["Bearer " <> supplied] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(key, supplied) do
      route(conn, config)
    else
      _ -> reply(conn, 401, %{"error" => "model_settings_unauthorized"})
    end
  end

  defp admin_key(config) do
    case ModelServices.credential(config["token_ref"]) do
      {:ok, {:env, _, key}} when byte_size(key) >= 32 -> {:ok, key}
      _ -> {:error, :model_settings_admin_unavailable}
    end
  end

  defp route(%{method: "GET", path_info: ["repositories"]} = conn, config) do
    repos = Enum.map(config["repositories"], fn {id, repo} -> %{"id" => id, "repository" => repo["repository"]} end)
    reply(conn, 200, %{"repositories" => repos})
  end

  defp route(%{method: "GET", path_info: ["repositories", id]} = conn, config),
    do: result(conn, ModelSettings.show(config, id))

  defp route(%{method: "POST", path_info: ["repositories", id]} = conn, config) do
    with [origin] <- get_req_header(conn, "origin"),
         true <- origin == config["origin"],
         ["application/json"] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <- read_body(conn, length: 16_384, read_length: 16_384),
         {:ok, request} <- Jason.decode(body) do
      result(conn, ModelSettings.save(config, id, request))
    else
      _ -> reply(conn, 403, %{"error" => "model_settings_request_refused"})
    end
  end

  defp route(conn, _), do: reply(conn, 404, %{"error" => "model_settings_not_found"})
  defp result(conn, {:ok, value}), do: reply(conn, 200, value)

  defp result(conn, {:error, reason}) do
    code = if reason in [:model_services_conflict, :model_services_busy], do: 409, else: 422
    error = if is_atom(reason), do: Atom.to_string(reason), else: "model_settings_save_failed"
    reply(conn, code, %{"error" => error})
  end

  defp reply(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> put_resp_header("cache-control", "no-store") |> put_resp_header("x-content-type-options", "nosniff") |> send_resp(status, Jason.encode!(body))
  end
end
