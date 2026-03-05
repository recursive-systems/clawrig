defmodule Clawrig.Node.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Clawrig.Node.Capabilities

  describe "manifest/0" do
    test "returns caps, commands, and permissions" do
      manifest = Capabilities.manifest()
      assert is_list(manifest["caps"])
      assert is_list(manifest["commands"])
      assert is_map(manifest["permissions"])
      assert "device" in manifest["caps"]
      assert "network.wifi.scan" in manifest["commands"]
    end
  end

  describe "invoke/2" do
    test "network.wifi.scan returns networks list" do
      assert {:ok, %{"networks" => networks}} = Capabilities.invoke("network.wifi.scan", %{})
      assert is_list(networks)
    end

    test "network.internet.check returns boolean" do
      assert {:ok, %{"connected" => connected}} = Capabilities.invoke("network.internet.check", %{})
      assert is_boolean(connected)
    end

    test "network.ip.detect returns IP string" do
      assert {:ok, %{"ip" => ip}} = Capabilities.invoke("network.ip.detect", %{})
      assert is_binary(ip)
    end

    test "gateway.status returns status string" do
      assert {:ok, %{"status" => status}} = Capabilities.invoke("gateway.status", %{})
      assert status in ["running", "stopped"]
    end

    test "hardware.temperature returns float" do
      assert {:ok, %{"temperature" => temp}} = Capabilities.invoke("hardware.temperature", %{})
      assert is_float(temp)
    end

    test "hardware.voltage returns float" do
      assert {:ok, %{"voltage" => volts}} = Capabilities.invoke("hardware.voltage", %{})
      assert is_float(volts)
    end

    test "hardware.throttled returns map" do
      assert {:ok, %{"throttled" => status}} = Capabilities.invoke("hardware.throttled", %{})
      assert is_map(status)
      assert Map.has_key?(status, "throttled")
    end

    test "unknown command returns error" do
      assert {:error, "unsupported command: foo.bar"} = Capabilities.invoke("foo.bar", %{})
    end

    test "network.wifi.connect without params returns error" do
      assert {:error, :missing_params} = Capabilities.invoke("network.wifi.connect", %{})
    end
  end
end
