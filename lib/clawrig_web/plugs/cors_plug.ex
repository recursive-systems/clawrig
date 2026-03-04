defmodule ClawrigWeb.Plugs.CorsPlug do
  @moduledoc """
  Adds CORS headers to allow cross-origin requests from local network tools.

  Scoped to specific API endpoints (e.g., status.json) that return
  non-sensitive device info. Uses `Access-Control-Allow-Origin: *`
  since the Pi serves on a local network with no secrets at these endpoints.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> handle_preflight()
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp handle_preflight(conn), do: conn
end
