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

  # CORS-enabled JSON API (local network tools, browser extensions)
  pipeline :api_public do
    plug :accepts, ["json"]
    plug ClawrigWeb.Plugs.CorsPlug
  end

  # CORS-enabled status endpoint (must be before captive scope to match first)
  scope "/portal", ClawrigWeb do
    pipe_through :api_public
    get "/status.json", WifiController, :status_json
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
    post "/portal/finish", WifiController, :finish
    get "/portal/status", WifiController, :status
    post "/portal/skip-wifi", WifiController, :skip_wifi
  end

  # Phase 2: LiveView wizard (home network)
  scope "/", ClawrigWeb do
    pipe_through :browser

    get "/login", AuthController, :new
    post "/login", AuthController, :create
    post "/logout", AuthController, :delete

    live_session :wizard,
      on_mount: [{ClawrigWeb.Hooks.ModeGuard, :oobe_only}] do
      live "/setup", WizardLive, :index
    end

    live_session :dashboard,
      on_mount: [
        {ClawrigWeb.Hooks.ModeGuard, :dashboard_only},
        {ClawrigWeb.Hooks.AuthGuard, :dashboard_auth}
      ] do
      live "/", DashboardLive, :index
      live "/wifi", DashboardLive, :wifi
      live "/account", DashboardLive, :account
      live "/telegram", DashboardLive, :telegram
      live "/integrations", DashboardLive, :integrations
      live "/system", DashboardLive, :system
    end
  end

  if Application.compile_env(:clawrig, :dev_routes) do
    scope "/__e2e__", ClawrigWeb do
      pipe_through :api

      post "/reset", E2eController, :reset
    end
  end
end
