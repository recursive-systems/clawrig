defmodule ClawrigWeb.WifiControllerTest do
  use ClawrigWeb.ConnCase

  alias Clawrig.Wizard.State
  alias Clawrig.Wifi.Manager

  setup do
    State.reset()
    _ = Manager.stop_hotspot()
    :ok
  end

  test "GET /portal renders network list", %{conn: conn} do
    conn = get(conn, "/portal")
    assert html_response(conn, 200) =~ "Wi-Fi Setup"
    assert html_response(conn, 200) =~ "MyHomeWiFi"
  end

  test "CNA detection endpoints redirect to /portal", %{conn: conn} do
    for path <- [
          "/generate_204",
          "/hotspot-detect.html",
          "/connecttest.txt",
          "/canonical.html",
          "/success.txt"
        ] do
      conn = get(conn, path)
      assert redirected_to(conn) == "/portal"
    end
  end

  test "POST /portal/connect renders connecting page", %{conn: conn} do
    conn = post(conn, "/portal/connect", %{ssid: "TestNetwork", password: "testpass"})
    assert html_response(conn, 200) =~ "Connecting"
    assert html_response(conn, 200) =~ "TestNetwork"
  end

  test "POST /portal/scan renders network list", %{conn: conn} do
    conn = post(conn, "/portal/scan")
    assert html_response(conn, 200) =~ "Wi-Fi Setup"
  end

  test "GET /portal/status renders status", %{conn: conn} do
    conn = get(conn, "/portal/status")
    assert html_response(conn, 200) =~ "Network Status"
  end

  test "GET /portal/status.json returns mode and handoff fields", %{conn: conn} do
    State.put(:local_ip, "192.168.1.77")

    conn = get(conn, "/portal/status.json")
    assert response(conn, 200)

    payload = Jason.decode!(response(conn, 200))

    assert Map.has_key?(payload, "mode")
    assert Map.has_key?(payload, "connecting")
    assert Map.has_key?(payload, "connected_ssid")
    assert Map.has_key?(payload, "last_error")
    assert payload["ip"] == "192.168.1.77"
  end
end
