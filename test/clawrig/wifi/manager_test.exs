defmodule Clawrig.Wifi.ManagerTest do
  use ExUnit.Case, async: false

  alias Clawrig.Wifi.Manager
  alias Clawrig.Wizard.State

  setup do
    State.reset()
    _ = Manager.stop_hotspot()
    :ok
  end

  test "status includes connecting and last_error fields" do
    status = Manager.status()

    assert Map.has_key?(status, :mode)
    assert Map.has_key?(status, :connecting)
    assert Map.has_key?(status, :connected_ssid)
    assert Map.has_key?(status, :last_error)
  end

  test "safe_connect transitions to station and persists IP with mock commands" do
    Manager.safe_connect("MyHomeWiFi", "secret")

    assert wait_until(fn -> Manager.status().connecting end, 2_000)

    assert wait_until(
             fn ->
               status = Manager.status()

               status.mode == :station and status.connected_ssid == "MyHomeWiFi" and
                 status.connecting == false
             end,
             5_000
           )

    assert State.get(:wifi_configured) == true
    assert State.get(:network_method) == :wifi
    assert State.get(:local_ip) == "192.168.1.42"
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(50)
        do_wait_until(fun, deadline)
      end
    end
  end
end
