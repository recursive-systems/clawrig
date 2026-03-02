defmodule ClawrigWeb.ModeRoutingTest do
  use ClawrigWeb.ConnCase

  describe "GET / when OOBE not complete" do
    test "redirects to /setup", %{conn: conn} do
      Application.put_env(:clawrig, :oobe_complete, false)
      on_exit(fn -> Application.delete_env(:clawrig, :oobe_complete) end)

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/setup"
    end
  end

  describe "GET / when OOBE complete" do
    test "shows dashboard", %{conn: conn} do
      Application.put_env(:clawrig, :oobe_complete, true)
      on_exit(fn -> Application.delete_env(:clawrig, :oobe_complete) end)

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "ClawRig"
    end
  end

  describe "GET /setup when OOBE complete" do
    test "redirects to /", %{conn: conn} do
      Application.put_env(:clawrig, :oobe_complete, true)
      on_exit(fn -> Application.delete_env(:clawrig, :oobe_complete) end)

      conn = get(conn, ~p"/setup")
      assert redirected_to(conn) == "/"
    end
  end
end
