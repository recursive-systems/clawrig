defmodule Clawrig.Gateway.SessionVersionTest do
  use ExUnit.Case, async: false

  alias Clawrig.Gateway.SessionVersion

  defmodule TestCommands do
    @behaviour Clawrig.System.Commands

    def scan_networks, do: []
    def connect_wifi(_ssid, _password), do: {:ok, nil}
    def start_hotspot, do: :ok
    def stop_hotspot, do: :ok
    def check_internet, do: true
    def run_openclaw(_args), do: {"ok\n", 0}
    def gateway_status, do: :running

    def start_gateway do
      send(test_pid(), :start_gateway)
      :ok
    end

    def invalidate_agent_sessions do
      send(test_pid(), :invalidate_agent_sessions)
      :ok
    end

    def install_gateway, do: :ok
    def detect_local_ip, do: "127.0.0.1"
    def has_ethernet_ip, do: false
    def run_codex_exec(_prompt, _schema_path), do: {"{}", 0}
    def cpu_temperature, do: nil
    def cpu_voltage, do: nil
    def throttle_status, do: %{}
    def tailscale_status, do: %{installed: false, running: false, ip: nil, hostname: nil}
    def tailscale_up(_auth_key), do: :ok
    def tailscale_down, do: :ok
    def tailscale_install, do: :ok
    def autoheal_status, do: %{}
    def autoheal_set_enabled(_enabled), do: :ok
    def autoheal_run_now, do: :ok
    def autoheal_recent_log(_limit), do: []

    defp test_pid do
      Process.get(:session_version_test_pid) || self()
    end
  end

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "clawrig-session-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    version_file = Path.join(tmp_dir, "VERSION")
    marker_file = Path.join(tmp_dir, ".openclaw/clawrig-session-version")

    File.write!(version_file, "1.2.3\n")

    original_commands = Application.get_env(:clawrig, :system_commands)
    original_version_file = Application.get_env(:clawrig, :clawrig_version_file)
    original_marker_file = Application.get_env(:clawrig, :gateway_session_version_file)

    Application.put_env(:clawrig, :system_commands, TestCommands)
    Application.put_env(:clawrig, :clawrig_version_file, version_file)
    Application.put_env(:clawrig, :gateway_session_version_file, marker_file)

    Process.put(:session_version_test_pid, self())

    on_exit(fn ->
      Process.delete(:session_version_test_pid)
      restore_env(:system_commands, original_commands)
      restore_env(:clawrig_version_file, original_version_file)
      restore_env(:gateway_session_version_file, original_marker_file)
      File.rm_rf(tmp_dir)
    end)

    {:ok, version_file: version_file, marker_file: marker_file}
  end

  test "reconcile invalidates sessions and restarts gateway when the version marker changes",
       %{marker_file: marker_file} do
    assert :ok = SessionVersion.reconcile()
    assert_receive :invalidate_agent_sessions
    assert_receive :start_gateway
    assert File.read!(marker_file) == "1.2.3\n"
  end

  test "reconcile is a noop when the marker already matches the current version", %{
    marker_file: marker_file
  } do
    File.mkdir_p!(Path.dirname(marker_file))
    File.write!(marker_file, "1.2.3\n")

    assert :noop = SessionVersion.reconcile()
    refute_received :invalidate_agent_sessions
    refute_received :start_gateway
  end

  defp restore_env(key, nil), do: Application.delete_env(:clawrig, key)
  defp restore_env(key, value), do: Application.put_env(:clawrig, key, value)
end
