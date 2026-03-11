import Config

config :clawrig,
  generators: [timestamp_type: :utc_datetime]

config :clawrig, ClawrigWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ClawrigWeb.ErrorHTML, json: ClawrigWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Clawrig.PubSub,
  live_view: [signing_salt: "YBMymIam"]

config :esbuild,
  version: "0.25.4",
  clawrig: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  clawrig_css: [
    args: ~w(css/app.css --bundle --outdir=../priv/static/assets/css),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :clawrig,
  fleet_enabled: false,
  fleet_transport: Clawrig.Fleet.HttpTransport,
  fleet_endpoint: nil,
  fleet_device_token: nil,
  fleet_org_slug: "default-org",
  fleet_org_name: "Default Organization",
  fleet_site_code: "default-site",
  fleet_site_name: "Default Site",
  fleet_interval_ms: 60_000,
  fleet_startup_delay_ms: 5_000,
  fleet_require_oobe: true,
  gateway_chat_session_key: "agent:main:main",
  gateway_operator_client: Clawrig.Gateway.OperatorClient

import_config "#{config_env()}.exs"
