defmodule ClawrigWeb.WifiControllerTest do
  use ClawrigWeb.ConnCase

  test "GET /wifi renders network list", %{conn: conn} do
    conn = get(conn, "/wifi")
    assert html_response(conn, 200) =~ "Wi-Fi Setup"
    assert html_response(conn, 200) =~ "MyHomeWiFi"
  end

  test "CNA detection endpoints redirect to /wifi", %{conn: conn} do
    for path <- [
          "/generate_204",
          "/hotspot-detect.html",
          "/connecttest.txt",
          "/canonical.html",
          "/success.txt"
        ] do
      conn = get(conn, path)
      assert redirected_to(conn) == "/wifi"
    end
  end

  test "POST /wifi/connect renders connecting page", %{conn: conn} do
    conn = post(conn, "/wifi/connect", %{ssid: "TestNetwork", password: "testpass"})
    assert html_response(conn, 200) =~ "Connecting"
    assert html_response(conn, 200) =~ "TestNetwork"
  end

  test "POST /wifi/scan renders network list", %{conn: conn} do
    conn = post(conn, "/wifi/scan")
    assert html_response(conn, 200) =~ "Wi-Fi Setup"
  end

  test "GET /wifi/status renders status", %{conn: conn} do
    conn = get(conn, "/wifi/status")
    assert html_response(conn, 200) =~ "Network Status"
  end
end
