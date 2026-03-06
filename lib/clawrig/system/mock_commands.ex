defmodule Clawrig.System.MockCommands do
  @behaviour Clawrig.System.Commands

  @impl true
  def scan_networks do
    [
      %{ssid: "MyHomeWiFi", signal: 85, security: "WPA2", freq: "2.4 GHz"},
      %{ssid: "Neighbors_5G", signal: 62, security: "WPA3", freq: "5 GHz"},
      %{ssid: "CoffeeShop", signal: 45, security: "WPA2", freq: "2.4 GHz"},
      %{ssid: "OpenNetwork", signal: 30, security: "", freq: "2.4 GHz"}
    ]
  end

  @impl true
  def connect_wifi(_ssid, _password) do
    Process.sleep(1500)
    {:ok, "192.168.1.42"}
  end

  @impl true
  def start_hotspot do
    :ok
  end

  @impl true
  def stop_hotspot do
    :ok
  end

  @impl true
  def check_internet do
    true
  end

  @impl true
  def run_openclaw(args) do
    case args do
      ["gateway", "status"] -> {"RPC probe: ok\n", 0}
      ["doctor"] -> {"All checks passed\n", 0}
      ["status"] -> {"Gateway running\n", 0}
      ["pairing", "list", "telegram", "--json"] -> {Jason.encode!(%{requests: []}), 0}
      ["pairing", "approve", "telegram", _code, "--notify"] -> {"Approved\n", 0}
      ["--version"] -> {"1.2.3\n", 0}
      ["channels", "add" | _] -> {"Channel added\n", 0}
      ["plugins", "enable" | _] -> {"Plugin enabled\n", 0}
      ["gateway", "install"] -> {"Installed\n", 0}
      ["onboard", "--install-daemon"] -> {"Daemon installed\n", 0}
      _ -> {"ok\n", 0}
    end
  end

  @impl true
  def gateway_status do
    :running
  end

  @impl true
  def start_gateway do
    :ok
  end

  @impl true
  def install_gateway do
    :ok
  end

  @impl true
  def detect_local_ip do
    "192.168.1.42"
  end

  @impl true
  def has_ethernet_ip do
    false
  end

  @impl true
  def run_codex_exec(_prompt, _schema_path) do
    {Jason.encode!(%{action: "none", reason: "mock: system healthy", confidence: 1.0}), 0}
  end

  @impl true
  def cpu_temperature, do: 45.2

  @impl true
  def cpu_voltage, do: 1.2

  @impl true
  def throttle_status do
    %{
      "raw" => "0x0",
      "under_voltage" => false,
      "frequency_capped" => false,
      "throttled" => false,
      "soft_temp_limit" => false
    }
  end

  @impl true
  def tailscale_status, do: %{installed: false, running: false, ip: nil, hostname: nil}
  @impl true
  def tailscale_up(_auth_key), do: {:error, "Not available in dev mode"}
  @impl true
  def tailscale_down, do: {:error, "Not available in dev mode"}
  @impl true
  def tailscale_install, do: {:error, "Not available in dev mode"}
end
