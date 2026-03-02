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
      ] ++ hotspot_task()

    opts = [strategy: :one_for_one, name: Clawrig.Supervisor]
    Supervisor.start_link(children, opts)
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
