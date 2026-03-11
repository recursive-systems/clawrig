import Config

config :clawrig, ClawrigWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Z8mYMtKM9CmP90AKcjhcahWVWalMC9L+vbsRjgKtVtnUMV0ARVyxJx1Uos0dRjTV",
  server: false

config :clawrig, :system_commands, Clawrig.System.MockCommands
config :clawrig, :state_path, Path.join(System.tmp_dir!(), "clawrig-test-wizard-state.json")
config :clawrig, :oobe_complete, false
config :clawrig, :gateway_operator_client, Clawrig.Gateway.MockOperatorClient

config :clawrig,
       :node_identity_path,
       Path.join(System.tmp_dir!(), "clawrig-test-node-identity.json")

config :clawrig,
       :dashboard_auth_path,
       Path.join(System.tmp_dir!(), "clawrig-test-dashboard-auth.json")

config :clawrig,
       :gateway_operator_store_path,
       Path.join(System.tmp_dir!(), "clawrig-test-gateway-operator.json")

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
