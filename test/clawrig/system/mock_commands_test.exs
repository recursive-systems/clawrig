defmodule Clawrig.System.MockCommandsTest do
  use ExUnit.Case, async: true

  alias Clawrig.System.MockCommands

  test "scan_networks returns list of networks" do
    networks = MockCommands.scan_networks()
    assert is_list(networks)
    assert length(networks) > 0

    first = hd(networks)
    assert Map.has_key?(first, :ssid)
    assert Map.has_key?(first, :signal)
    assert Map.has_key?(first, :security)
  end

  test "connect_wifi returns {:ok, ip}" do
    assert {:ok, _ip} = MockCommands.connect_wifi("test", "pass")
  end

  test "check_internet returns true" do
    assert MockCommands.check_internet() == true
  end

  test "check_openclaw returns version" do
    assert {:ok, _version} = MockCommands.check_openclaw()
  end

  test "install_openclaw returns version" do
    assert {:ok, _version} = MockCommands.install_openclaw()
  end

  test "gateway_status returns :running" do
    assert MockCommands.gateway_status() == :running
  end

  test "invalidate_agent_sessions returns :ok" do
    assert :ok = MockCommands.invalidate_agent_sessions()
  end

  test "run_openclaw handles various commands" do
    assert {"RPC probe: ok\n", 0} = MockCommands.run_openclaw(["gateway", "status"])
    assert {_, 0} = MockCommands.run_openclaw(["--version"])
  end
end
