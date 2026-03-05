defmodule Clawrig.DeviceIdentity do
  @moduledoc """
  Single source of truth for per-device identity (hostname, SSID, mDNS address).

  All values derive from the system hostname, which is set at deploy time by
  `pi-setup.sh` (e.g. "clawrig-a3f7" or "clawrig-kitchen").
  """

  @doc """
  Returns the system hostname (e.g. "clawrig-a3f7").
  """
  def hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "clawrig"
    end
  end

  @doc """
  Returns the mDNS address (e.g. "clawrig-a3f7.local").
  """
  def mdns_address do
    "#{hostname()}.local"
  end

  @doc """
  Returns the mDNS URL (e.g. "http://clawrig-a3f7.local").
  """
  def mdns_url do
    "http://#{mdns_address()}"
  end

  @doc """
  Returns the hotspot SSID derived from hostname.

  "clawrig-a3f7" -> "ClawRig-A3F7-Setup"
  "clawrig"      -> "ClawRig-Setup"
  """
  def hotspot_ssid do
    case String.split(hostname(), "-", parts: 2) do
      [_, suffix] -> "ClawRig-#{String.upcase(suffix)}-Setup"
      _ -> "ClawRig-Setup"
    end
  end

  @doc """
  Returns the NetworkManager connection name for the hotspot.
  """
  def hotspot_conn_name do
    case String.split(hostname(), "-", parts: 2) do
      [_, suffix] -> "ClawRig-#{String.upcase(suffix)}-Hotspot"
      _ -> "ClawRig-Hotspot"
    end
  end
end
