defmodule ClawrigWeb.WifiController do
  use ClawrigWeb, :controller

  alias Clawrig.Wifi.Manager
  alias Clawrig.System.Commands

  def redirect_wifi(conn, _params) do
    conn
    |> put_resp_header("location", "/portal")
    |> send_resp(302, "")
  end

  def index(conn, _params) do
    {:ok, networks} = Manager.scan()
    eth_online = Commands.impl().has_ethernet_ip() and Commands.impl().check_internet()
    render(conn, :index, networks: networks, eth_online: eth_online)
  end

  def skip_wifi(conn, _params) do
    ip = Commands.impl().detect_local_ip()

    Clawrig.Wizard.State.merge(%{
      network_method: :ethernet,
      local_ip: ip
    })

    render(conn, :continue_on_computer, ip: ip, mdns_url: Clawrig.DeviceIdentity.mdns_url())
  end

  def scan(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks)
  end

  def connect(conn, %{"ssid" => ssid, "password" => password}) do
    # Respond with transition page, then attempt connection asynchronously.
    # safe_connect tears down the hotspot, tries WiFi, and restarts the
    # hotspot if the connection fails — so the user is never locked out.
    Manager.safe_connect(ssid, password)
    render(conn, :connecting, ssid: ssid, mdns_url: Clawrig.DeviceIdentity.mdns_url())
  end

  def connect(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks, error: "Please select a network.")
  end

  def status(conn, _params) do
    status = Manager.status()
    render(conn, :status, status: status)
  end

  def status_json(conn, _params) do
    status = Manager.status()
    ip = Clawrig.Wizard.State.get(:local_ip)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{mode: status.mode, ip: ip}))
  end
end
