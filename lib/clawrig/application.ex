defmodule Clawrig.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ClawrigWeb.Telemetry,
        {Phoenix.PubSub, name: Clawrig.PubSub},
        Clawrig.Wifi.Manager,
        Clawrig.Wizard.State,
        Clawrig.Updater,
        ClawrigWeb.Endpoint
      ] ++ oauth_listener() ++ hotspot_task()

    opts = [strategy: :one_for_one, name: Clawrig.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # OAuth redirect URI is hardcoded to localhost:1455 (registered with OpenAI).
  # In dev, the main app runs on 4090, so start a second listener on 1455.
  defp oauth_listener do
    port = 1455
    main_port = Application.get_env(:clawrig, ClawrigWeb.Endpoint)[:http][:port] || 4090

    if port != main_port do
      [{Bandit, plug: ClawrigWeb.Endpoint, port: port, scheme: :http}]
    else
      []
    end
  end

  defp hotspot_task do
    if Application.get_env(:clawrig, :env) == :prod do
      [
        {Task, fn ->
          state = Clawrig.Wizard.State.get()

          if !state.wifi_configured do
            Clawrig.Wifi.Manager.start_hotspot()
          end
        end}
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ClawrigWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
