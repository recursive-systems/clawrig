defmodule Clawrig.Gateway.OperatorStoreTest do
  use ExUnit.Case, async: true

  alias Clawrig.Gateway.OperatorStore

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "clawrig-operator-store-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:clawrig, :gateway_operator_store_path, path)

    on_exit(fn ->
      Application.delete_env(:clawrig, :gateway_operator_store_path)
      File.rm(path)
    end)

    :ok
  end

  test "generates a keypair and persists a device token" do
    identity = OperatorStore.identity()

    assert is_binary(identity.public_key)
    assert is_binary(identity.private_key)
    assert is_binary(identity.device_id)
    assert identity.device_token == nil

    assert :ok = OperatorStore.put_device_token("device-token-1")
    assert OperatorStore.identity().device_token == "device-token-1"

    assert :ok = OperatorStore.clear_device_token()
    assert OperatorStore.identity().device_token == nil
  end
end
