defmodule ClawrigWeb.DashboardLiveTest do
  use ClawrigWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Clawrig.Integrations.Config
  alias Clawrig.TestSupport.MockTelegramHTTP

  setup do
    original_home = System.get_env("HOME")
    original_plugin_root = Application.get_env(:clawrig, :openclaw_plugin_install_root)

    home =
      Path.join(System.tmp_dir!(), "clawrig-dashboard-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    System.put_env("HOME", home)

    plugin_root =
      Path.join(
        System.tmp_dir!(),
        "clawrig-dashboard-plugin-#{System.unique_integer([:positive])}"
      )

    plugin_dir = Path.join(plugin_root, "clawrig")
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "openclaw.plugin.json"), "{}")
    Application.put_env(:clawrig, :openclaw_plugin_install_root, plugin_root)
    :ok = Config.write_plugin_defaults()

    original_http = Application.get_env(:clawrig, :telegram_http)
    Application.put_env(:clawrig, :telegram_http, MockTelegramHTTP)
    MockTelegramHTTP.reset()

    Application.put_env(:clawrig, :oobe_complete, true)
    Application.put_env(:clawrig, :enable_preview_states, true)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_plugin_root,
        do: Application.put_env(:clawrig, :openclaw_plugin_install_root, original_plugin_root),
        else: Application.delete_env(:clawrig, :openclaw_plugin_install_root)

      if original_http,
        do: Application.put_env(:clawrig, :telegram_http, original_http),
        else: Application.delete_env(:clawrig, :telegram_http)

      Application.delete_env(:clawrig, :oobe_complete)
      Application.delete_env(:clawrig, :enable_preview_states)
      File.rm_rf(home)
      File.rm_rf(plugin_root)
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

  describe "dashboard integrations" do
    test "renders the skills center with the default clawrig skill", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/integrations")

      assert html =~ "Skills"
      assert html =~ "ClawRig"
      assert html =~ "Bundled with every device"
      assert html =~ "PDF Export"
      assert html =~ "Coming soon"
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

  describe "dashboard telegram" do
    test "renders telegram setup section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/telegram")
      assert html =~ "Owner Phone Setup"
      assert html =~ "Set up Telegram"
    end

    test "validates token and links the owner chat", %{conn: conn} do
      token = "123:abc"

      MockTelegramHTTP.put_get_me(
        token,
        {:ok,
         %{
           status: 200,
           body: %{
             "ok" => true,
             "result" => %{"first_name" => "Pi Bot", "username" => "pi_bot"}
           }
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/telegram")

      view |> element("button[phx-click=tg_dashboard_start]") |> render_click()

      view
      |> element("form[phx-submit=tg_dashboard_validate]")
      |> render_submit(%{"token" => token})

      html = render(view)
      assert html =~ "Tap Start in Telegram"

      [_, nonce] = Regex.run(~r/start=(clawrig_[A-Za-z0-9_-]+)/, html)

      MockTelegramHTTP.put_updates(
        token,
        {:ok,
         %{
           status: 200,
           body: %{
             "ok" => true,
             "result" => [
               %{
                 "update_id" => 21,
                 "message" => %{
                   "chat" => %{"type" => "private", "id" => 456, "first_name" => "Bradley"},
                   "text" => "/start #{nonce}"
                 }
               }
             ]
           }
         }}
      )

      view |> element("button[phx-click=tg_dashboard_check]") |> render_click()
      html = render(view)
      assert html =~ "Send test notification"
      assert html =~ "Disconnect Telegram"

      assert {:connected, %{bot_token: ^token, allow_from: ["456"], dm_policy: "allowlist"}} =
               Config.telegram_status()

      assert [
               {^token, "sendMessage",
                %{
                  "chat_id" => "456",
                  "text" => text
                }}
             ] = MockTelegramHTTP.sent_messages()

      assert text =~ "Telegram is connected to your ClawRig dashboard"
    end

    test "disconnect removes telegram config", %{conn: conn} do
      assert :ok = Config.write_telegram("123:abc", "456")

      {:ok, view, _html} = live(conn, ~p"/telegram")

      html = view |> element("button[phx-click=tg_dashboard_disconnect]") |> render_click()

      assert html =~ "Owner Phone Setup"
      assert :not_configured = Config.telegram_status()
    end

    test "relink restores previous telegram config when validation fails", %{conn: conn} do
      token = "123:abc"
      assert :ok = Config.write_telegram(token, "456")

      {:ok, view, _html} = live(conn, ~p"/telegram")
      MockTelegramHTTP.put_get_me(token, {:error, :offline})

      view |> element("button[phx-click=tg_dashboard_relink]") |> render_click()
      _ = render(view)
      html = render(view)

      assert html =~ "Disconnect Telegram"

      assert {:connected, %{bot_token: ^token, allow_from: ["456"], dm_policy: "allowlist"}} =
               Config.telegram_status()
    end
  end
end
