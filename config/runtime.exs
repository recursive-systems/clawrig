import Config

if System.get_env("PHX_SERVER") do
  config :clawrig, ClawrigWeb.Endpoint, server: true
end

config :clawrig, ClawrigWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4090"))]

if config_env() == :prod do
  # Wizard state persistence path (only override in prod)
  config :clawrig,
         :state_path,
         System.get_env("CLAWRIG_STATE_PATH", "/var/lib/clawrig/wizard-state.json")

  config :clawrig,
         :node_identity_path,
         System.get_env("CLAWRIG_NODE_IDENTITY_PATH", "/var/lib/clawrig/node-identity.json")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  default_host =
    case :inet.gethostname() do
      {:ok, name} -> "#{name}.local"
      _ -> "clawrig.local"
    end

  host = System.get_env("PHX_HOST", default_host)

  fleet_interval_ms =
    case Integer.parse(System.get_env("CLAWRIG_FLEET_INTERVAL_MS", "60000")) do
      {value, _} -> value
      :error -> 60_000
    end

  config :clawrig,
         :fleet_enabled,
         System.get_env("CLAWRIG_FLEET_ENABLED", "false") == "true"

  config :clawrig,
         :fleet_endpoint,
         System.get_env("CLAWRIG_FLEET_ENDPOINT")

  config :clawrig,
         :fleet_device_token,
         System.get_env("CLAWRIG_FLEET_DEVICE_TOKEN")

  config :clawrig,
         :fleet_org_slug,
         System.get_env("CLAWRIG_FLEET_ORG_SLUG", "default-org")

  config :clawrig,
         :fleet_org_name,
         System.get_env("CLAWRIG_FLEET_ORG_NAME", "Default Organization")

  config :clawrig,
         :fleet_site_code,
         System.get_env("CLAWRIG_FLEET_SITE_CODE", "default-site")

  config :clawrig,
         :fleet_site_name,
         System.get_env("CLAWRIG_FLEET_SITE_NAME", "Default Site")

  config :clawrig,
         :fleet_interval_ms,
         fleet_interval_ms

  config :clawrig,
         :fleet_require_oobe,
         System.get_env("CLAWRIG_FLEET_REQUIRE_OOBE", "true") == "true"

  config :clawrig, ClawrigWeb.Endpoint,
    url: [host: host, port: 80, scheme: "http"],
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4090"))
    ],
    check_origin: false,
    secret_key_base: secret_key_base
end
