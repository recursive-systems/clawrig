defmodule Clawrig.Fleet.SenderTest do
  use ExUnit.Case, async: false

  defmodule TestTransport do
    @behaviour Clawrig.Fleet.Transport

    @impl true
    def send_heartbeat(payload) do
      if pid = Application.get_env(:clawrig, :fleet_test_pid) do
        send(pid, {:fleet_heartbeat, payload})
      end

      {:ok, :no_directives}
    end
  end

  setup do
    keys = [
      :fleet_enabled,
      :fleet_require_oobe,
      :fleet_interval_ms,
      :fleet_startup_delay_ms,
      :fleet_transport,
      :fleet_test_pid,
      :system_commands
    ]

    original = for key <- keys, into: %{}, do: {key, Application.get_env(:clawrig, key)}

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:clawrig, key),
          else: Application.put_env(:clawrig, key, value)
      end)
    end)

    :ok
  end

  test "sender emits heartbeat when enabled" do
    Application.put_env(:clawrig, :fleet_enabled, true)
    Application.put_env(:clawrig, :fleet_require_oobe, false)
    Application.put_env(:clawrig, :fleet_interval_ms, 50)
    Application.put_env(:clawrig, :fleet_startup_delay_ms, 0)
    Application.put_env(:clawrig, :fleet_transport, TestTransport)
    Application.put_env(:clawrig, :fleet_test_pid, self())
    Application.put_env(:clawrig, :system_commands, Clawrig.System.MockCommands)

    start_supervised!({Clawrig.Fleet.Sender, name: :fleet_sender_test_enabled})

    assert_receive {:fleet_heartbeat, payload}, 1_000
    assert payload["metrics"]["gateway_status"] == "running"
  end

  test "sender does not emit heartbeat when disabled" do
    Application.put_env(:clawrig, :fleet_enabled, false)
    Application.put_env(:clawrig, :fleet_require_oobe, false)
    Application.put_env(:clawrig, :fleet_interval_ms, 50)
    Application.put_env(:clawrig, :fleet_startup_delay_ms, 0)
    Application.put_env(:clawrig, :fleet_transport, TestTransport)
    Application.put_env(:clawrig, :fleet_test_pid, self())
    Application.put_env(:clawrig, :system_commands, Clawrig.System.MockCommands)

    start_supervised!({Clawrig.Fleet.Sender, name: :fleet_sender_test_disabled})

    refute_receive {:fleet_heartbeat, _payload}, 300
  end
end
