defmodule ClawrigWeb.DashboardLiveTest do
  use ClawrigWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:clawrig, :oobe_complete, true)
    System.put_env("CLAWRIG_ENABLE_PREVIEW_STATES", "true")

    on_exit(fn ->
      Application.delete_env(:clawrig, :oobe_complete)
      System.delete_env("CLAWRIG_ENABLE_PREVIEW_STATES")
    end)

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
      html = view |> element(~s|nav.dash-nav a[href="/wifi"]|) |> render_click()
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

    test "renders pending recovery preview copy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system?preview=update-pending-recovery")
      assert html =~ "Update paused for safety"
      assert html =~ "connected through Tailscale"
    end

    test "renders pending reauth preview copy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system?preview=update-pending-reauth")
      assert html =~ "Reconnect OpenAI to continue"
      assert html =~ "Open Account Settings"
    end

    test "renders ready retry preview copy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system?preview=update-ready-retry")
      assert html =~ "Ready to retry update"
      assert html =~ "Retry Update Now"
    end
  end
end
