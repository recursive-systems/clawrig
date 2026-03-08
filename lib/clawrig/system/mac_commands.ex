defmodule Clawrig.System.MacCommands do
  @moduledoc """
  Real WiFi scanning on macOS via CoreWLAN. Connect/hotspot are no-ops.
  Other commands delegate to MockCommands.
  """

  @behaviour Clawrig.System.Commands

  @scan_script """
  import CoreWLAN
  let client = CWWiFiClient.shared()
  if let iface = client.interface() {
      if let networks = try? iface.scanForNetworks(withSSID: nil) {
          for net in networks.sorted(by: { ($0.rssiValue) > ($1.rssiValue) }) {
              let ssid = net.ssid ?? ""
              if ssid.isEmpty { continue }
              let rssi = net.rssiValue
              let signal = min(100, max(0, 2 * (Int(rssi) + 100)))
              let band = net.wlanChannel?.channelBand == .band5GHz ? "5 GHz" : (net.wlanChannel?.channelBand == .band6GHz ? "6 GHz" : "2.4 GHz")
              print("\\(ssid)\\t\\(signal)\\t\\(band)")
          }
      }
  }
  """

  @impl true
  def scan_networks do
    case System.cmd("swift", ["-e", @scan_script], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.ssid)

      _ ->
        []
    end
  end

  defp parse_line(line) do
    case String.split(line, "\t") do
      [ssid, signal, freq] ->
        %{
          ssid: ssid,
          signal: String.to_integer(signal),
          security: "WPA2",
          freq: freq
        }

      _ ->
        nil
    end
  end

  # Connect is a no-op on macOS dev (don't change real WiFi)
  @impl true
  def connect_wifi(_ssid, _password) do
    Process.sleep(1500)
    {:ok, "192.168.1.42"}
  end

  @impl true
  def start_hotspot, do: :ok

  @impl true
  def stop_hotspot, do: :ok

  # Delegate non-WiFi commands to MockCommands
  @impl true
  defdelegate check_internet, to: Clawrig.System.MockCommands
  @impl true
  defdelegate run_openclaw(args), to: Clawrig.System.MockCommands
  @impl true
  defdelegate gateway_status, to: Clawrig.System.MockCommands
  @impl true
  defdelegate start_gateway, to: Clawrig.System.MockCommands
  @impl true
  defdelegate install_gateway, to: Clawrig.System.MockCommands
  @impl true
  defdelegate detect_local_ip, to: Clawrig.System.MockCommands
  @impl true
  defdelegate has_ethernet_ip, to: Clawrig.System.MockCommands
  @impl true
  defdelegate run_codex_exec(prompt, schema_path), to: Clawrig.System.MockCommands
  @impl true
  defdelegate cpu_temperature, to: Clawrig.System.MockCommands
  @impl true
  defdelegate cpu_voltage, to: Clawrig.System.MockCommands
  @impl true
  defdelegate throttle_status, to: Clawrig.System.MockCommands
  @impl true
  defdelegate tailscale_status, to: Clawrig.System.MockCommands
  @impl true
  defdelegate tailscale_up(auth_key), to: Clawrig.System.MockCommands
  @impl true
  defdelegate tailscale_down, to: Clawrig.System.MockCommands
  @impl true
  defdelegate tailscale_install, to: Clawrig.System.MockCommands
  @impl true
  defdelegate autoheal_status, to: Clawrig.System.MockCommands
  @impl true
  defdelegate autoheal_set_enabled(enabled), to: Clawrig.System.MockCommands
  @impl true
  defdelegate autoheal_run_now, to: Clawrig.System.MockCommands
  @impl true
  defdelegate autoheal_recent_log(limit), to: Clawrig.System.MockCommands
end
