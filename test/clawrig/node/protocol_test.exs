defmodule Clawrig.Node.ProtocolTest do
  use ExUnit.Case, async: true

  alias Clawrig.Node.Protocol

  describe "encode_request/3" do
    test "produces valid JSON with correct structure" do
      json = Protocol.encode_request(1, "connect", %{"role" => "node"})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "req"
      assert decoded["id"] == 1
      assert decoded["method"] == "connect"
      assert decoded["params"] == %{"role" => "node"}
    end
  end

  describe "encode_response/3" do
    test "encodes success response" do
      json = Protocol.encode_response(1, true, %{"status" => "ok"})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "res"
      assert decoded["id"] == 1
      assert decoded["ok"] == true
      assert decoded["payload"] == %{"status" => "ok"}
    end

    test "encodes error response" do
      json = Protocol.encode_response(1, false, %{"reason" => "not found"})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "res"
      assert decoded["id"] == 1
      assert decoded["ok"] == false
      assert decoded["error"] == %{"reason" => "not found"}
    end
  end

  describe "encode_event/2" do
    test "produces valid event frame" do
      json = Protocol.encode_event("connect.challenge", %{"nonce" => "abc"})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "event"
      assert decoded["event"] == "connect.challenge"
      assert decoded["payload"] == %{"nonce" => "abc"}
    end
  end

  describe "decode/1" do
    test "decodes request frame" do
      json = Jason.encode!(%{"type" => "req", "id" => 5, "method" => "node.invoke", "params" => %{"command" => "test"}})
      assert {:req, 5, "node.invoke", %{"command" => "test"}} = Protocol.decode(json)
    end

    test "decodes success response" do
      json = Jason.encode!(%{"type" => "res", "id" => 1, "ok" => true, "payload" => %{"v" => 1}})
      assert {:res, 1, true, %{"v" => 1}} = Protocol.decode(json)
    end

    test "decodes error response" do
      json = Jason.encode!(%{"type" => "res", "id" => 1, "ok" => false, "error" => %{"reason" => "bad"}})
      assert {:res, 1, false, %{"reason" => "bad"}} = Protocol.decode(json)
    end

    test "decodes event frame" do
      json = Jason.encode!(%{"type" => "event", "event" => "connect.challenge", "payload" => %{"nonce" => "x"}})
      assert {:event, "connect.challenge", %{"nonce" => "x"}} = Protocol.decode(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = Protocol.decode("not json")
    end

    test "returns error for unknown frame structure" do
      json = Jason.encode!(%{"type" => "unknown"})
      assert {:error, "unknown frame structure"} = Protocol.decode(json)
    end

    test "round-trips encode → decode for requests" do
      json = Protocol.encode_request(42, "test.method", %{"key" => "value"})
      assert {:req, 42, "test.method", %{"key" => "value"}} = Protocol.decode(json)
    end
  end
end
