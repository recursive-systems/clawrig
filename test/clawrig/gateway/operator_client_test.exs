defmodule Clawrig.Gateway.OperatorClientTest do
  use ExUnit.Case, async: false

  alias Clawrig.Gateway.{MockTransport, OperatorClient, OperatorStore}
  alias Clawrig.Node.Protocol

  setup do
    original_transport = Application.get_env(:clawrig, :gateway_transport)
    original_auth_path = Application.get_env(:clawrig, :gateway_shared_auth_path)
    original_store_path = Application.get_env(:clawrig, :gateway_operator_store_path)
    original_oobe = Application.get_env(:clawrig, :oobe_complete)
    original_commands = Application.get_env(:clawrig, :system_commands)

    start_supervised!(MockTransport)
    MockTransport.reset()

    auth_dir =
      Path.join(System.tmp_dir!(), "clawrig-gateway-auth-#{System.unique_integer([:positive])}")

    File.mkdir_p!(auth_dir)
    auth_path = Path.join(auth_dir, "openclaw.json")

    File.write!(
      auth_path,
      Jason.encode!(%{"gateway" => %{"auth" => %{"token" => "test-shared-token"}}})
    )

    store_dir =
      Path.join(System.tmp_dir!(), "clawrig-gateway-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(store_dir)
    store_path = Path.join(store_dir, "gateway-operator.json")

    Application.put_env(:clawrig, :gateway_operator_store_path, store_path)
    :ok = OperatorStore.clear_device_token()

    Application.put_env(:clawrig, :gateway_transport, MockTransport)
    Application.put_env(:clawrig, :gateway_shared_auth_path, auth_path)
    Application.put_env(:clawrig, :oobe_complete, true)
    Application.put_env(:clawrig, :system_commands, Clawrig.System.MockCommands)

    on_exit(fn ->
      File.rm_rf(auth_dir)
      File.rm_rf(store_dir)

      if original_transport do
        Application.put_env(:clawrig, :gateway_transport, original_transport)
      else
        Application.delete_env(:clawrig, :gateway_transport)
      end

      if original_auth_path do
        Application.put_env(:clawrig, :gateway_shared_auth_path, original_auth_path)
      else
        Application.delete_env(:clawrig, :gateway_shared_auth_path)
      end

      if original_store_path do
        Application.put_env(:clawrig, :gateway_operator_store_path, original_store_path)
      else
        Application.delete_env(:clawrig, :gateway_operator_store_path)
      end

      if is_nil(original_oobe) do
        Application.delete_env(:clawrig, :oobe_complete)
      else
        Application.put_env(:clawrig, :oobe_complete, original_oobe)
      end

      if original_commands do
        Application.put_env(:clawrig, :system_commands, original_commands)
      end
    end)

    :ok
  end

  test "pair_local_admin sends a Gateway-compatible connect payload and stores the device token" do
    challenge = {:text, Protocol.encode_event("connect.challenge", %{"nonce" => "nonce-1"})}

    hello_ok =
      {:text,
       Protocol.encode_response("connect-1", true, %{
         "type" => "hello-ok",
         "auth" => %{"deviceToken" => "device-token-123"},
         "policy" => %{"tickIntervalMs" => 10_000},
         "methods" => ["chat.history", "chat.send", "chat.abort", "exec.approval.resolve"],
         "events" => ["chat", "agent", "exec.approval.requested"]
       })}

    MockTransport.push_responses([
      {:ok, [challenge]},
      {:ok, [hello_ok]},
      {:ok, [challenge]},
      {:ok, [hello_ok]}
    ])

    start_supervised!({OperatorClient, name: OperatorClient})

    assert :ok = OperatorClient.pair_local_admin()
    assert OperatorClient.status() == :connected
    assert OperatorStore.identity().device_token == "device-token-123"

    assert {:text, connect_frame} = List.last(MockTransport.sent_frames())
    assert {:req, "connect-1", "connect", params} = Protocol.decode(connect_frame)

    assert params["client"]["id"] == "gateway-client"
    assert params["client"]["mode"] == "backend"
    assert params["device"]["publicKey"] =~ ~r/^[A-Za-z0-9_-]+$/
    assert params["device"]["signature"] =~ ~r/^[A-Za-z0-9_-]+$/
    refute String.contains?(params["device"]["publicKey"], "=")
    refute String.contains?(params["device"]["signature"], "=")
  end

  test "connect_check uses shared gateway auth even without a stored device token" do
    challenge = {:text, Protocol.encode_event("connect.challenge", %{"nonce" => "nonce-startup"})}

    hello_ok =
      {:text,
       Protocol.encode_response("connect-1", true, %{
         "type" => "hello-ok",
         "auth" => %{},
         "policy" => %{"tickIntervalMs" => 10_000},
         "methods" => ["chat.history", "chat.send"],
         "events" => ["chat", "agent"]
       })}

    MockTransport.push_responses([{:ok, [challenge]}, {:ok, [hello_ok]}])

    start_supervised!({OperatorClient, name: OperatorClient})
    Process.sleep(50)

    assert OperatorClient.status() == :connected
    assert OperatorStore.identity().device_token == nil
  end
end
