defmodule Clawrig.Fleet.Transport do
  @moduledoc """
  Behaviour for sending generic fleet heartbeats.
  """

  @type directive :: %{String.t() => term()}

  @type heartbeat_result ::
          {:ok, [directive()]}
          | {:ok, :no_directives}
          | {:error, term()}

  @callback send_heartbeat(payload :: map()) :: heartbeat_result()
end
