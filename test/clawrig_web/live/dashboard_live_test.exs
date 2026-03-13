defmodule ClawrigWeb.DashboardLiveTest do
  use ClawrigWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Clawrig.Integrations.Config
  alias Clawrig.TestSupport.MockBrowserUseBrokerHTTP
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

    original_browser_http = Application.get_env(:clawrig, :browser_use_broker_http)
    Application.put_env(:clawrig, :browser_use_broker_http, MockBrowserUseBrokerHTTP)
    MockBrowserUseBrokerHTTP.reset()

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

      if original_browser_http,
        do: Application.put_env(:clawrig, :browser_use_broker_http, original_browser_http),
        else: Application.delete_env(:clawrig, :browser_use_broker_http)

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
      assert html =~ "Browser Use"
      assert html =~ "PDF Export"
      assert html =~ "Coming soon"
    end

    test "enables managed browser use trial from the dashboard", %{conn: conn} do
      MockBrowserUseBrokerHTTP.put_register_result(
        {:ok, %{status: 201, body: %{"token" => "cbu_dev_123"}}}
      )

      MockBrowserUseBrokerHTTP.put_usage_result(
        "cbu_dev_123",
        {:ok,
         %{
           status: 200,
           body: %{
             "used_usd" => "0.20",
             "remaining_usd" => "2.80",
             "budget_usd" => "3.00",
             "estimated_runs_left" => 14,
             "global_available" => true
           }
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/integrations")

      _ = view |> element("button[phx-click=browser_enable_trial]") |> render_click()
      send(view.pid, {:browser_register_result, {:ok, %{"token" => "cbu_dev_123"}}})
      html = render(view)

      assert html =~ "Browser automation enabled with ClawRig trial"
      assert :managed_trial = Config.browser_mode()
    end

    test "supports browser use byok and removal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/integrations")

      view |> element("button[phx-click=browser_show_byok]") |> render_click()

      html =
        view
        |> element("form[phx-submit=browser_submit_api_key]")
        |> render_submit(%{"api_key" => "bu_test_key"})

      assert html =~ "Browser automation enabled with your Browser Use Cloud key"
      assert :byok = Config.browser_mode()

      html = view |> element("button[phx-click=browser_remove]") |> render_click()

      assert html =~ "Enable Browser Trial"
      assert :not_configured = Config.browser_mode()
    end

    test "keeps the browser use byok form open during refresh polling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/integrations")
      view |> element("button[phx-click=browser_show_byok]") |> render_click()

      send(view.pid, :refresh_status)
      html = render(view)

      assert html =~ "Browser Use Cloud API Key"
    end

    test "shows the global exhaustion message for managed browser use", %{conn: conn} do
      assert :ok = Config.write_browser_trial("cbu_dev_123")

      {:ok, view, _html} = live(conn, ~p"/integrations")

      send(
        view.pid,
        {:status_result, :running, true, "Test WiFi", false, :not_configured, nil, :managed_trial,
         %{
           "used_usd" => "3.00",
           "remaining_usd" => "0.00",
           "budget_usd" => "3.00",
           "estimated_runs_left" => 0,
           "global_available" => false,
           "message" =>
             "ClawRig's shared Browser Use trial pool is full for this month. Add your own Browser Use Cloud key to continue."
         }, %{installed: false, running: false, ip: nil, hostname: nil},
         %{"enabled" => true}, [], %{}}
      )

      html = render(view)

      assert html =~ "shared Browser Use trial pool is full"
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
