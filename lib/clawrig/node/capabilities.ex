defmodule Clawrig.Node.Capabilities do
  @moduledoc """
  Registry and dispatcher for OpenClaw node capabilities.

  Maps `node.invoke` commands to existing system functions and Pi hardware queries.
  """

  alias Clawrig.System.Commands

  @caps ["system", "network", "device", "hardware"]

  @commands [
    "network.wifi.scan",
    "network.wifi.status",
    "network.wifi.connect",
    "network.internet.check",
    "network.ip.detect",
    "device.version",
    "device.uptime",
    "device.storage",
    "device.health",
    "gateway.status",
    "gateway.restart",
    "hardware.temperature",
    "hardware.voltage",
    "hardware.throttled"
  ]

  @permissions %{
    "network.wifi.connect" => true,
    "gateway.restart" => true
  }

  def caps, do: @caps
  def commands, do: @commands
  def permissions, do: @permissions

  @doc """
  Returns the full capability manifest for the connect handshake.
  """
  def manifest do
    %{
      "caps" => @caps,
      "commands" => @commands,
      "permissions" => @permissions
    }
  end

  @doc """
  Dispatches a command to the appropriate handler.

  Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  def invoke("network.wifi.scan", _params) do
    networks = Commands.impl().scan_networks()
    {:ok, %{"networks" => networks}}
  end

  def invoke("network.wifi.status", _params) do
    case Clawrig.Wifi.Manager.status() do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  def invoke("network.wifi.connect", %{"ssid" => ssid, "password" => password}) do
    case Clawrig.Wifi.Manager.connect(ssid, password) do
      {:ok, ip} -> {:ok, %{"ip" => ip}}
      {:error, reason} -> {:error, reason}
    end
  end

  def invoke("network.wifi.connect", _params) do
    {:error, :missing_params}
  end

  def invoke("network.internet.check", _params) do
    {:ok, %{"connected" => Commands.impl().check_internet()}}
  end

  def invoke("network.ip.detect", _params) do
    {:ok, %{"ip" => Commands.impl().detect_local_ip()}}
  end

  def invoke("device.version", _params) do
    version =
      case File.read("/opt/clawrig/VERSION") do
        {:ok, v} -> String.trim(v)
        _ -> "0.0.0-dev"
      end

    {:ok, %{"version" => version}}
  end

  def invoke("device.uptime", _params) do
    case System.cmd("uptime", ["-p"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, %{"uptime" => String.trim(output)}}
      {output, _} -> {:error, "uptime failed: #{String.trim(output)}"}
    end
  end

  def invoke("device.storage", _params) do
    case System.cmd("df", ["-h", "/"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, %{"storage" => String.trim(output)}}
      {output, _} -> {:error, "df failed: #{String.trim(output)}"}
    end
  end

  def invoke("device.health", _params) do
    result = Clawrig.Diagnostics.Agent.check_now()
    {:ok, %{"health" => result}}
  end

  def invoke("gateway.status", _params) do
    {:ok, %{"status" => to_string(Commands.impl().gateway_status())}}
  end

  def invoke("gateway.restart", _params) do
    Commands.impl().start_gateway()
    {:ok, %{"status" => "restarting"}}
  end

  def invoke("hardware.temperature", _params) do
    {:ok, %{"temperature" => Commands.impl().cpu_temperature()}}
  end

  def invoke("hardware.voltage", _params) do
    {:ok, %{"voltage" => Commands.impl().cpu_voltage()}}
  end

  def invoke("hardware.throttled", _params) do
    {:ok, %{"throttled" => Commands.impl().throttle_status()}}
  end

  def invoke(command, _params) do
    {:error, "unsupported command: #{command}"}
  end
end
