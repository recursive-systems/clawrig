defmodule Clawrig.Integrations.ConfigTest do
  use ExUnit.Case, async: false

  alias Clawrig.Integrations.Config

  setup do
    original_home = System.get_env("HOME")

    home =
      Path.join(
        System.tmp_dir!(),
        "clawrig-integrations-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf(home)
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

  test "remove_telegram removes channel config" do
    assert :ok = Config.write_telegram("123:abc", "456")
    assert :ok = Config.remove_telegram()
    assert :not_configured = Config.telegram_status()
    assert is_nil(Config.telegram_config())
  end
end
