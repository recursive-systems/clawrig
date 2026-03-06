defmodule Clawrig.Wifi.Watchdog do
  @moduledoc """
  Monitors Wi-Fi connectivity and falls back to hotspot mode when the
  device loses its network connection (e.g. password changed, moved to
  a new location). Only runs in prod after OOBE is complete.

  Check interval: 60 s
  Failure threshold: 3 consecutive failures (~3 min) before fallback
  Skips fallback when ethernet is connected (device is still reachable).
  """

  use GenServer

  require Logger

  alias Clawrig.System.Commands
  alias Clawrig.Wifi.Manager

  @check_interval :timer.seconds(60)
  @failure_threshold 3

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    if enabled?() do
      schedule_check()
      {:ok, %{failures: 0}}
    else
      {:ok, %{failures: 0}}
    end
  end

  @impl true
  def handle_info(:check, state) do
    state = do_check(state)
    schedule_check()
    {:noreply, state}
  end

  defp do_check(state) do
    status = Manager.status()

    # Don't interfere if we're already in AP (hotspot) mode
    if status.mode == :ap do
      %{state | failures: 0}
    else
      case wifi_healthy?() do
        true ->
          if state.failures > 0 do
            Logger.info("[WifiWatchdog] Connectivity restored after #{state.failures} failure(s)")
          end

          %{state | failures: 0}

        false ->
          failures = state.failures + 1

          Logger.warning(
            "[WifiWatchdog] Connectivity check failed (#{failures}/#{@failure_threshold})"
          )

          if failures >= @failure_threshold do
            maybe_start_hotspot()
            %{state | failures: 0}
          else
            %{state | failures: failures}
          end
      end
    end
  end

  defp wifi_healthy? do
    # Check if wlan0 has an IP by looking for a connected SSID via the manager,
    # then verify we can actually reach the network gateway.
    commands = Commands.impl()

    case commands.detect_local_ip() do
      nil -> false
      _ip -> commands.check_internet()
    end
  end

  defp maybe_start_hotspot do
    commands = Commands.impl()

    if commands.has_ethernet_ip() do
      Logger.info(
        "[WifiWatchdog] Wi-Fi lost but ethernet is connected — skipping hotspot fallback"
      )

      Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:wifi", {:wifi_lost, :ethernet_fallback})
    else
      Logger.warning("[WifiWatchdog] Wi-Fi lost, starting hotspot for reconfiguration")
      Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:wifi", {:wifi_lost, :hotspot_started})

      # Scan while still in station mode to cache networks for the portal
      Manager.scan()

      case Manager.start_hotspot() do
        :ok ->
          Logger.info("[WifiWatchdog] Hotspot started successfully")

        {:error, reason} ->
          Logger.error("[WifiWatchdog] Failed to start hotspot: #{inspect(reason)}")
      end
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end

  defp enabled? do
    Application.get_env(:clawrig, :env) == :prod and oobe_complete?()
  end

  defp oobe_complete? do
    marker = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
    File.exists?(marker)
  end
end
