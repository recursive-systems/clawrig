defmodule ClawrigWeb.Router do
  use ClawrigWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClawrigWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ClawrigWeb.Plugs.ModePlug
  end

  # Captive portal pipeline — no CSRF (CNA browsers don't support it)
  pipeline :captive do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClawrigWeb.Layouts, :wifi_root}
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Phase 1: CNA detection endpoints (captive portal)
  scope "/", ClawrigWeb do
    pipe_through :captive

    get "/generate_204", WifiController, :redirect_wifi
    get "/hotspot-detect.html", WifiController, :redirect_wifi
    get "/connecttest.txt", WifiController, :redirect_wifi
    get "/canonical.html", WifiController, :redirect_wifi
    get "/success.txt", WifiController, :redirect_wifi

    get "/portal", WifiController, :index
    post "/portal/scan", WifiController, :scan
    post "/portal/connect", WifiController, :connect
    get "/portal/status", WifiController, :status
  end

  # Phase 2: LiveView wizard (home network)
  scope "/", ClawrigWeb do
    pipe_through :browser

    live_session :wizard,
      on_mount: [{ClawrigWeb.Hooks.ModeGuard, :oobe_only}] do
      live "/setup", WizardLive, :index
    end

    live_session :dashboard,
      on_mount: [{ClawrigWeb.Hooks.ModeGuard, :dashboard_only}] do
      live "/", DashboardLive, :index
      live "/wifi", DashboardLive, :wifi
      live "/account", DashboardLive, :account
      live "/telegram", DashboardLive, :telegram
      live "/system", DashboardLive, :system
    end
  end
end
