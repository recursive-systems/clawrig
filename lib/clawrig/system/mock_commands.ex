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
  def check_openclaw do
    {:ok, "1.2.3"}
  end

  @impl true
  def install_openclaw do
    Process.sleep(2000)
    {:ok, "1.2.3"}
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
end
