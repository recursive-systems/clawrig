defmodule Clawrig.Gateway.Transport do
  @moduledoc false

  defstruct [:conn, :ref, :websocket]

  def connect(host, port, path \\ "/") do
    with {:ok, conn} <- Mint.HTTP.connect(:http, host, port, mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, websocket, buffered_data} <- await_upgrade(conn, ref) do
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}, buffered_data}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
      {:error, _conn, reason, _responses} -> {:error, reason}
    end
  end

  def set_mode(%__MODULE__{conn: conn} = state, mode) do
    case Mint.HTTP.set_mode(conn, mode) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, reason} -> {:error, %{state | conn: conn}, reason}
    end
  end

  def recv(%__MODULE__{} = state, timeout \\ 10_000) do
    socket = Mint.HTTP.get_socket(state.conn)

    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> decode(state, data)
      {:error, reason} -> {:error, state, reason}
    end
  end

  def decode(%__MODULE__{} = state, data) when is_binary(data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        {:ok, %{state | websocket: websocket}, frames}

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  def stream(%__MODULE__{conn: conn, websocket: websocket, ref: ref} = state, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        Enum.reduce_while(responses, {:ok, state, []}, fn
          {:data, ^ref, data}, {:ok, st, frames} ->
            case decode(st, data) do
              {:ok, st, new_frames} -> {:cont, {:ok, st, frames ++ new_frames}}
              {:error, st, reason} -> {:halt, {:error, st, reason}}
            end

          _, {:ok, st, frames} ->
            {:cont, {:ok, st, frames}}
        end)

      {:error, conn, reason, _responses} ->
        {:error, %{state | conn: conn, websocket: websocket}, reason}

      :unknown ->
        :unknown
    end
  end

  def send_frame(%__MODULE__{} = state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, reason} -> {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  def close(%__MODULE__{conn: conn}) when not is_nil(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  def close(_state), do: :ok

  defp await_upgrade(conn, ref) do
    with {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, 5_000) do
      {status, headers, data_parts} =
        Enum.reduce(responses, {nil, [], []}, fn
          {:status, ^ref, status}, {_, headers, data} -> {status, headers, data}
          {:headers, ^ref, headers}, {status, _, data} -> {status, headers, data}
          {:data, ^ref, data}, {status, headers, parts} -> {status, headers, parts ++ [data]}
          _, acc -> acc
        end)

      if status == 101 do
        case Mint.WebSocket.new(conn, ref, status, headers) do
          {:ok, conn, websocket} ->
            buffered = if data_parts == [], do: nil, else: IO.iodata_to_binary(data_parts)
            {:ok, conn, websocket, buffered}

          {:error, conn, reason} ->
            {:error, conn, reason}
        end
      else
        {:error, conn, {:upgrade_failed, status}}
      end
    end
  end
end
