import Config

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

# Use MockCommands in dev (works on macOS without nmcli)
config :clawrig, :system_commands, Clawrig.System.MacCommands
config :clawrig, :state_path, "wizard-state.json"
config :clawrig, :oobe_marker, ".oobe-complete"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
