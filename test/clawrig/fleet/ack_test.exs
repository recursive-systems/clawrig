defmodule Clawrig.Fleet.AckTest do
  use ExUnit.Case, async: false

  alias Clawrig.Fleet.Ack

  setup do
    # The Ack agent is started by the application supervisor.
    # Drain any leftover state to ensure a clean slate for each test.
    Ack.drain()
    :ok
  end

  test "enqueue then drain returns ack with correct id, status, and at field" do
    Ack.enqueue("dir-1", :success)
    [ack] = Ack.drain()

    assert ack["id"] == "dir-1"
    assert ack["status"] == "success"
    assert {:ok, _dt, 0} = DateTime.from_iso8601(ack["at"])
  end

  test "multiple enqueues drain in FIFO order" do
    Ack.enqueue("a", :success)
    Ack.enqueue("b", :failed)
    Ack.enqueue("c", :pending)

    acks = Ack.drain()
    assert Enum.map(acks, & &1["id"]) == ["a", "b", "c"]
  end

  test "drain clears the queue" do
    Ack.enqueue("x", :success)
    [_] = Ack.drain()

    assert Ack.drain() == []
  end

  test "statuses are stringified" do
    Ack.enqueue("1", :success)
    Ack.enqueue("2", :unknown_type)

    [first, second] = Ack.drain()
    assert first["status"] == "success"
    assert second["status"] == "unknown_type"
  end
end
