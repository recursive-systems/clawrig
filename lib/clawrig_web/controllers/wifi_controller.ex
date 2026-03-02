defmodule ClawrigWeb.WifiController do
  use ClawrigWeb, :controller

  alias Clawrig.Wifi.Manager

  def redirect_wifi(conn, _params) do
    conn
    |> put_resp_header("location", "/portal")
    |> send_resp(302, "")
  end

  def index(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks)
  end

  def scan(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks)
  end

  def connect(conn, %{"ssid" => ssid, "password" => password}) do
    # Respond immediately with transition page
    conn = render(conn, :connecting, ssid: ssid)

    # Schedule the actual connection after response is sent
    Task.start(fn ->
      Process.sleep(3000)
      Manager.stop_hotspot()
      Manager.connect(ssid, password)
    end)

    conn
  end

  def connect(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks, error: "Please select a network.")
  end

  def status(conn, _params) do
    status = Manager.status()
    render(conn, :status, status: status)
  end
end
