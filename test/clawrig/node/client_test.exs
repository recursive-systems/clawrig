defmodule Clawrig.Node.ClientTest do
  use ExUnit.Case, async: false

  alias Clawrig.Node.Client

  test "status_detail exposes node runtime diagnostics" do
    detail = Client.status_detail()

    assert is_map(detail)
    assert Map.has_key?(detail, :status)
    assert Map.has_key?(detail, :last_error)
    assert Map.has_key?(detail, :last_connected_at)
    assert Map.has_key?(detail, :last_disconnected_at)
    assert Map.has_key?(detail, :reconnect_attempts)
  end
end
