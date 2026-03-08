defmodule ClawrigWeb.DashboardLiveTest do
  use ClawrigWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:clawrig, :oobe_complete, true)
    on_exit(fn -> Application.delete_env(:clawrig, :oobe_complete) end)
    :ok
  end

  describe "dashboard index" do
    test "renders status section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Dashboard"
      assert html =~ "OpenClaw"
    end
  end

  describe "dashboard wifi" do
    test "renders wifi section", %{conn: conn} do
      # /wifi is also matched by the captive portal scope, so navigate via live_patch
      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element(~s|a[href="/wifi"]|) |> render_click()
      assert html =~ "Wi-Fi"
    end
  end

  describe "dashboard account" do
    test "renders account section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/account")
      assert html =~ "AI Provider"
    end
  end

  describe "dashboard system" do
    test "renders system section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")
      assert html =~ "System"
      assert html =~ "Auto-healing"
      assert html =~ "Run Fix Now"
    end
  end
end
