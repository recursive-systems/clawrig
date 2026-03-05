import Config

if System.get_env("PHX_SERVER") do
  config :clawrig, ClawrigWeb.Endpoint, server: true
end

config :clawrig, ClawrigWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4090"))]

# Search proxy registration secret (all environments)
config :clawrig,
  search_proxy_secret: System.get_env("SEARCH_PROXY_SECRET", "")

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

  config :clawrig, ClawrigWeb.Endpoint,
    url: [host: host, port: 80, scheme: "http"],
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4090"))
    ],
    check_origin: false,
    secret_key_base: secret_key_base
end
