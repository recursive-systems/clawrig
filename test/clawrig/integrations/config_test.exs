defmodule Clawrig.Integrations.ConfigTest do
  use ExUnit.Case, async: false

  alias Clawrig.Integrations.Config

  setup do
    original_home = System.get_env("HOME")
    original_plugin_root = Application.get_env(:clawrig, :openclaw_plugin_install_root)

    home =
      Path.join(
        System.tmp_dir!(),
        "clawrig-integrations-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    System.put_env("HOME", home)

    plugin_root =
      Path.join(
        System.tmp_dir!(),
        "clawrig-plugin-root-#{System.unique_integer([:positive])}"
      )

    plugin_dir = Path.join(plugin_root, "clawrig")
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "openclaw.plugin.json"), "{}")
    Application.put_env(:clawrig, :openclaw_plugin_install_root, plugin_root)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_plugin_root,
        do: Application.put_env(:clawrig, :openclaw_plugin_install_root, original_plugin_root),
        else: Application.delete_env(:clawrig, :openclaw_plugin_install_root)

      File.rm_rf(home)
      File.rm_rf(plugin_root)
    end)

    :ok
  end

  test "write_telegram writes allowlist config and status" do
    assert :ok = Config.write_telegram("123:abc", "456")

    assert {:connected, %{bot_token: "123:abc", allow_from: ["456"], dm_policy: "allowlist"}} =
             Config.telegram_status()

    assert %{
             "enabled" => true,
             "botToken" => "123:abc",
             "dmPolicy" => "allowlist",
             "allowFrom" => ["456"]
           } = Config.telegram_config()
  end

  test "exec_security_mode returns not_configured on empty config" do
    assert "not_configured" = Config.exec_security_mode()
  end

  test "write_exec_defaults sets full security" do
    assert :ok = Config.write_exec_defaults()
    assert "full" = Config.exec_security_mode()
  end

  test "write_exec_defaults preserves existing config" do
    :ok = Config.write_telegram("123:abc", "456")
    :ok = Config.write_exec_defaults()
    assert {:connected, _} = Config.telegram_status()
    assert "full" = Config.exec_security_mode()
  end

  test "write_exec_defaults is idempotent" do
    :ok = Config.write_exec_defaults()
    :ok = Config.write_exec_defaults()
    assert "full" = Config.exec_security_mode()
  end

  test "write_plugin_defaults enables the bundled clawrig plugin without dropping other config" do
    :ok = Config.write_telegram("123:abc", "456")
    assert :ok = Config.write_plugin_defaults()

    config =
      home_config_path()
      |> File.read!()
      |> Jason.decode!()

    assert get_in(config, ["plugins", "load", "paths"]) == [
             Application.fetch_env!(:clawrig, :openclaw_plugin_install_root)
           ]

    assert get_in(config, ["plugins", "entries", "clawrig", "enabled"]) == true
    assert get_in(config, ["channels", "telegram", "botToken"]) == "123:abc"
  end

  test "skills_center reports enabled clawrig plus optional entries" do
    assert :ok = Config.write_plugin_defaults()

    assert [
             %{id: "clawrig", state: "enabled", source: "default"},
             %{id: "web-search", state: "disabled", source: "optional"},
             %{id: "pdf-export", state: "coming_soon", source: "optional"}
           ] = Config.skills_center()
  end

  test "remove_telegram removes channel config" do
    assert :ok = Config.write_telegram("123:abc", "456")
    assert :ok = Config.remove_telegram()
    assert :not_configured = Config.telegram_status()
    assert is_nil(Config.telegram_config())
  end

  defp home_config_path do
    Path.join([System.get_env("HOME"), ".openclaw", "openclaw.json"])
  end
end
