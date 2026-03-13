defmodule Clawrig.Integrations.ManagedDefaultsTest do
  use ExUnit.Case, async: false

  alias Clawrig.Integrations.Config
  alias Clawrig.Integrations.ManagedDefaults
  alias Clawrig.TestSupport.MockBrowserUseBrokerHTTP
  alias Clawrig.TestSupport.MockSearchProxyHTTP

  defmodule TestCommands do
    @behaviour Clawrig.System.Commands

    def scan_networks, do: []
    def connect_wifi(_ssid, _password), do: {:ok, nil}
    def start_hotspot, do: :ok
    def stop_hotspot, do: :ok
    def check_internet, do: true
    def run_openclaw(_args), do: {"ok\n", 0}
    def gateway_status, do: :running
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

    def start_gateway do
      send(test_pid(), :start_gateway)
      :ok
    end

    def invalidate_agent_sessions do
      send(test_pid(), :invalidate_agent_sessions)
      :ok
    end

    defp test_pid do
      Process.get(:managed_defaults_test_pid) || self()
    end
  end

  setup do
    original_home = System.get_env("HOME")
    original_plugin_root = Application.get_env(:clawrig, :openclaw_plugin_install_root)
    original_search_http = Application.get_env(:clawrig, :search_proxy_http)
    original_browser_http = Application.get_env(:clawrig, :browser_use_broker_http)
    original_commands = Application.get_env(:clawrig, :system_commands)

    home =
      Path.join(
        System.tmp_dir!(),
        "clawrig-managed-defaults-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    System.put_env("HOME", home)

    plugin_root =
      Path.join(
        System.tmp_dir!(),
        "clawrig-managed-defaults-plugin-root-#{System.unique_integer([:positive])}"
      )

    plugin_dir = Path.join(plugin_root, "clawrig")
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "openclaw.plugin.json"), "{}")

    Application.put_env(:clawrig, :openclaw_plugin_install_root, plugin_root)
    Application.put_env(:clawrig, :search_proxy_http, MockSearchProxyHTTP)
    Application.put_env(:clawrig, :browser_use_broker_http, MockBrowserUseBrokerHTTP)
    Application.put_env(:clawrig, :system_commands, TestCommands)

    MockSearchProxyHTTP.reset()
    MockBrowserUseBrokerHTTP.reset()

    Process.put(:managed_defaults_test_pid, self())

    on_exit(fn ->
      Process.delete(:managed_defaults_test_pid)

      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      restore_env(:openclaw_plugin_install_root, original_plugin_root)
      restore_env(:search_proxy_http, original_search_http)
      restore_env(:browser_use_broker_http, original_browser_http)
      restore_env(:system_commands, original_commands)

      File.rm_rf(home)
      File.rm_rf(plugin_root)
    end)

    :ok
  end

  test "reconcile auto-enables managed search and browser when both are missing" do
    MockSearchProxyHTTP.put_register_result(
      {:ok, %{status: 201, body: %{"token" => "search_dev_123"}}}
    )

    MockBrowserUseBrokerHTTP.put_register_result(
      {:ok, %{status: 201, body: %{"deviceToken" => "browser_dev_123"}}}
    )

    assert {:ok, [:search, :browser]} = ManagedDefaults.reconcile()
    assert :managed = Config.search_mode()
    assert :managed_trial = Config.browser_mode()
    assert_receive :invalidate_agent_sessions
    assert_receive :start_gateway
    assert %{device_id: _device_id, hostname: _hostname} =
             MockSearchProxyHTTP.last_register_payload()

    assert %{organization: %{slug: "default-org", name: "Default Organization"}} =
             MockBrowserUseBrokerHTTP.last_register_payload()
  end

  test "reconcile leaves existing byok config alone" do
    assert :ok = Config.write_brave_key("BSA-user-key")
    assert :ok = Config.write_browser_api_key("bu_user_key")

    assert :noop = ManagedDefaults.reconcile()
    assert :byok = Config.search_mode()
    assert :byok = Config.browser_mode()
    refute_received :invalidate_agent_sessions
    refute_received :start_gateway
    assert is_nil(MockSearchProxyHTTP.last_register_payload())
    assert is_nil(MockBrowserUseBrokerHTTP.last_register_payload())
  end

  test "reconcile respects explicit opt-outs and does not auto-register" do
    assert :ok = Config.remove_search_config()
    assert :ok = Config.remove_browser_config()

    assert :noop = ManagedDefaults.reconcile()
    assert Config.search_auto_opt_out?()
    assert Config.browser_auto_opt_out?()
    refute_received :invalidate_agent_sessions
    refute_received :start_gateway
    assert is_nil(MockSearchProxyHTTP.last_register_payload())
    assert is_nil(MockBrowserUseBrokerHTTP.last_register_payload())
  end

  test "reconcile restarts once when only browser auto-enable succeeds" do
    MockSearchProxyHTTP.put_register_result({:error, %{reason: :timeout}})

    MockBrowserUseBrokerHTTP.put_register_result(
      {:ok, %{status: 201, body: %{"deviceToken" => "browser_dev_123"}}}
    )

    assert {:ok, [:browser]} = ManagedDefaults.reconcile()
    assert :not_configured = Config.search_mode()
    assert :managed_trial = Config.browser_mode()
    assert_receive :invalidate_agent_sessions
    assert_receive :start_gateway
  end

  defp restore_env(key, nil), do: Application.delete_env(:clawrig, key)
  defp restore_env(key, value), do: Application.put_env(:clawrig, key, value)
end
