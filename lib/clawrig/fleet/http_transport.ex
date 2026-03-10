defmodule Clawrig.Fleet.HttpTransport do
  @moduledoc """
  HTTP transport implementation for fleet heartbeat delivery.
  """

  @behaviour Clawrig.Fleet.Transport

  @impl true
  def send_heartbeat(payload) when is_map(payload) do
    endpoint = Application.get_env(:clawrig, :fleet_endpoint)
    token = Application.get_env(:clawrig, :fleet_device_token)

    cond do
      is_nil(endpoint) or endpoint == "" ->
        {:error, :missing_endpoint}

      is_nil(token) or token == "" ->
        {:error, :missing_token}

      true ->
        case Req.post(endpoint,
               json: payload,
               headers: [{"authorization", "Bearer #{token}"}],
               receive_timeout: 8_000,
               retry: false
             ) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: status, body: body}} ->
            {:error, {:unexpected_status, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
