defmodule Clawrig.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ClawrigWeb.Telemetry,
        {Phoenix.PubSub, name: Clawrig.PubSub},
        {Task.Supervisor, name: Clawrig.TaskSupervisor},
        Clawrig.Wifi.Manager,
        Clawrig.Wifi.Watchdog,
        Clawrig.Wizard.State,
        Clawrig.Updater,
        Clawrig.Diagnostics.Agent,
        Clawrig.Node.Client,
        ClawrigWeb.Endpoint
      ] ++ hotspot_task()

    opts = [strategy: :one_for_one, name: Clawrig.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp hotspot_task do
    if Application.get_env(:clawrig, :env) == :prod do
      [
        {Task,
         fn ->
           oobe_marker =
             Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")

           state = Clawrig.Wizard.State.get()

           if !state.wifi_configured && !File.exists?(oobe_marker) do
             # Scan while wlan0 is still in station mode — once we start the
             # AP the radio can't scan. Results are cached in the Manager.
             Clawrig.Wifi.Manager.scan()
             start_hotspot_with_retry(3)
           end
         end}
      ]
    else
      []
    end
  end

  defp start_hotspot_with_retry(0) do
    require Logger
    Logger.error("Failed to start hotspot after all retries")
    {:error, :retries_exhausted}
  end

  defp start_hotspot_with_retry(retries) do
    require Logger

    case Clawrig.Wifi.Manager.start_hotspot() do
      :ok ->
        Logger.info("#{Clawrig.DeviceIdentity.hotspot_ssid()} hotspot started successfully")
        :ok

      {:error, reason} ->
        Logger.warning("Hotspot start failed (#{retries} retries left): #{inspect(reason)}")
        Process.sleep(5_000)
        start_hotspot_with_retry(retries - 1)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ClawrigWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
