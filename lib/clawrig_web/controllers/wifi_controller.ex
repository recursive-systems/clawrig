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
    # Don't connect yet — show confirmation page with the mDNS URL so the
    # user can note it down. The actual connection happens when they click Finish,
    # which tears down the hotspot (and this captive portal page with it).
    eth_ip = if Commands.impl().has_ethernet_ip(), do: Commands.impl().detect_local_ip()

    conn
    |> put_session(:wifi_ssid, ssid)
    |> put_session(:wifi_password, password)
    |> render(:connecting,
      ssid: ssid,
      mdns_url: Clawrig.DeviceIdentity.mdns_url(),
      eth_ip: eth_ip
    )
  end

  def connect(conn, _params) do
    {:ok, networks} = Manager.scan()
    render(conn, :index, networks: networks, error: "Please select a network.")
  end

  def finish(conn, _params) do
    ssid = get_session(conn, :wifi_ssid)
    password = get_session(conn, :wifi_password)

    mdns_url = Clawrig.DeviceIdentity.mdns_url()
    eth_ip = if Commands.impl().has_ethernet_ip(), do: Commands.impl().detect_local_ip()

    if ssid && password do
      Manager.safe_connect(ssid, password)
    end

    conn
    |> delete_session(:wifi_ssid)
    |> delete_session(:wifi_password)
    |> render(:finishing, ssid: ssid || "your network", mdns_url: mdns_url, eth_ip: eth_ip)
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
