defmodule Clawrig.Fleet.ConfigTest do
  use ExUnit.Case, async: false

  alias Clawrig.Fleet.Config

  setup do
    tmp = Path.join(System.tmp_dir!(), "fleet-config-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "fleet-config.json")
    Application.put_env(:clawrig, :fleet_config_path, path)

    on_exit(fn ->
      Application.delete_env(:clawrig, :fleet_config_path)
      File.rm_rf!(tmp)
    end)

    %{config_path: path}
  end

  describe "merge/1 and get/0" do
    test "writes config and reads it back" do
      assert :ok = Config.merge(%{"update_channel" => "stable"})
      assert %{"update_channel" => "stable"} = Config.get()
    end

    test "merges without clobbering existing keys" do
      :ok = Config.merge(%{"update_channel" => "stable"})
      :ok = Config.merge(%{"pause_updates" => true})

      config = Config.get()
      assert config["update_channel"] == "stable"
      assert config["pause_updates"] == true
    end

    test "only keeps allowed keys (sanitization)" do
      :ok = Config.merge(%{"update_channel" => "beta", "evil_key" => "nope"})

      config = Config.get()
      assert config["update_channel"] == "beta"
      refute Map.has_key?(config, "evil_key")
    end
  end

  describe "get/2" do
    test "returns default when key is absent" do
      assert Config.get("missing_key", :default) == :default
    end

    test "returns nil when key is absent and no default given" do
      assert Config.get("missing_key") == nil
    end
  end

  describe "corrupt JSON" do
    test "returns empty map for corrupt file", %{config_path: path} do
      File.write!(path, "not valid json{{{")
      assert Config.get() == %{}
    end
  end

  describe "PubSub broadcast" do
    test "fires :config_updated on successful merge" do
      Phoenix.PubSub.subscribe(Clawrig.PubSub, "clawrig:fleet_config")

      :ok = Config.merge(%{"update_channel" => "nightly"})

      assert_receive {:config_updated, %{"update_channel" => "nightly"}}
    end
  end
end
