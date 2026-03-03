import Config

config :clawrig, ClawrigWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Use real PiCommands in production
config :clawrig, :system_commands, Clawrig.System.PiCommands
config :clawrig, :env, :prod
config :clawrig, :device_code_module, Clawrig.Wizard.DeviceCode

config :logger, level: :info
