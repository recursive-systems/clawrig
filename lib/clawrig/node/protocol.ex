defmodule Clawrig.Node.Protocol do
  @moduledoc """
  OpenClaw Gateway protocol message encoding/decoding.

  Handles JSON serialization for:
  - Request frames: {type: "req", id, method, params}
  - Response frames: {type: "res", id, ok, payload|error}
  - Event frames: {type: "event", event, payload}
  """

  @doc """
  Encodes a request into a JSON-serialized WebSocket frame.

  Returns a string ready to send over the WebSocket.
  """
  def encode_request(id, method, params) do
    %{
      "type" => "req",
      "id" => id,
      "method" => method,
      "params" => params
    }
    |> Jason.encode!()
  end

  @doc """
  Encodes a response into a JSON-serialized WebSocket frame.

  `ok` is a boolean; on success include `payload`, on error include `error`.
  """
  def encode_response(id, true, payload) do
    %{
      "type" => "res",
      "id" => id,
      "ok" => true,
      "payload" => payload
    }
    |> Jason.encode!()
  end

  def encode_response(id, false, error) do
    %{
      "type" => "res",
      "id" => id,
      "ok" => false,
      "error" => error
    }
    |> Jason.encode!()
  end

  @doc """
  Encodes an event frame.
  """
  def encode_event(event_name, payload) do
    %{
      "type" => "event",
      "event" => event_name,
      "payload" => payload
    }
    |> Jason.encode!()
  end

  @doc """
  Decodes a JSON frame into a structured message.

  Returns:
  - `{:req, id, method, params}`
  - `{:res, id, ok, payload}` (ok=true) or `{:res, id, ok, error}` (ok=false)
  - `{:event, event_name, payload}`
  - `{:error, reason}`
  """
  def decode(json) when is_binary(json) do
    with {:ok, frame} <- Jason.decode(json) do
      decode_frame(frame)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --- Private ---

  defp decode_frame(%{"type" => "req", "id" => id, "method" => method, "params" => params}) do
    {:req, id, method, params}
  end

  defp decode_frame(%{"type" => "res", "id" => id, "ok" => true, "payload" => payload}) do
    {:res, id, true, payload}
  end

  defp decode_frame(%{"type" => "res", "id" => id, "ok" => false, "error" => error}) do
    {:res, id, false, error}
  end

  defp decode_frame(%{"type" => "event", "event" => event_name, "payload" => payload}) do
    {:event, event_name, payload}
  end

  defp decode_frame(_) do
    {:error, "unknown frame structure"}
  end
end
