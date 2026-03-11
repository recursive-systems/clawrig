defmodule Clawrig.Fleet.Ack do
  @moduledoc """
  Manages directive acknowledgment queue.

  Acks are batched into the next heartbeat payload, avoiding separate HTTP calls.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def enqueue(directive_id, status) do
    ack = %{
      "id" => directive_id,
      "status" => to_string(status),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    Agent.update(__MODULE__, fn acks -> [ack | acks] end)
  end

  def drain do
    Agent.get_and_update(__MODULE__, fn acks -> {Enum.reverse(acks), []} end)
  end
end
