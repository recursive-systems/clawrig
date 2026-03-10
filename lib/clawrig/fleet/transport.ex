defmodule Clawrig.Fleet.Transport do
  @moduledoc """
  Behaviour for sending generic fleet heartbeats.
  """

  @callback send_heartbeat(payload :: map()) :: :ok | {:error, term()}
end
