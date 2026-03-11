import Config

system_commands =
  case System.get_env("CLAWRIG_SYSTEM_COMMANDS", "mac") do
    "mock" -> Clawrig.System.MockCommands
    "mac" -> Clawrig.System.MacCommands
    other -> raise "Unsupported CLAWRIG_SYSTEM_COMMANDS in dev: #{inspect(other)}"
  end

state_path = System.get_env("CLAWRIG_STATE_PATH", "wizard-state.json")
oobe_marker = System.get_env("CLAWRIG_OOBE_MARKER", ".oobe-complete")
node_identity_path = System.get_env("CLAWRIG_NODE_IDENTITY_PATH", "priv/node-identity.json")
dashboard_auth_path = System.get_env("CLAWRIG_DASHBOARD_AUTH_PATH", "priv/dashboard-auth.json")
gateway_operator_store_path =
  System.get_env("CLAWRIG_GATEWAY_OPERATOR_STORE_PATH", "priv/gateway-operator.json")

# NOTE: If localhost:4090 hits Docker instead of Phoenix, use 127.0.0.1:4090 directly.
# Docker Desktop's gvproxy may claim port 4090 on IPv6.
config :clawrig, ClawrigWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4090],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "WOEVJoVEGvtXQvId85SZikg6l6j98Eo/gzqM/ZUS1ZP/EWVPGorZEjOc2D+RxmsO",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:clawrig, ~w(--sourcemap=inline --watch)]},
    esbuild_css: {Esbuild, :install_and_run, [:clawrig_css, ~w(--watch)]}
  ]

config :clawrig, ClawrigWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/clawrig_web/router\.ex$",
      ~r"lib/clawrig_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :clawrig, dev_routes: true

# Use mock or macOS command shims in dev so browser-based testing can run without a Pi.
config :clawrig, :system_commands, system_commands
config :clawrig, :state_path, state_path
config :clawrig, :oobe_marker, oobe_marker
config :clawrig, :device_code_module, Clawrig.Wizard.MockDeviceCode
config :clawrig, :node_identity_path, node_identity_path
config :clawrig, :dashboard_auth_path, dashboard_auth_path
config :clawrig, :gateway_operator_store_path, gateway_operator_store_path

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
