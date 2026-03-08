defmodule Clawrig.Node.Client do
  @moduledoc """
  WebSocket client that connects to the local OpenClaw Gateway as a node.

  Implements the Gateway handshake protocol (connect.challenge → connect → hello-ok),
  maintains heartbeat, dispatches `node.invoke` RPC calls to capabilities, and
  reconnects with exponential backoff on failure.

  Only connects when OOBE is complete and the Gateway is running.
  """

  use GenServer
  require Logger

  alias Clawrig.Node.{Identity, Protocol, Capabilities}
  alias Clawrig.System.Commands

  @gateway_host "127.0.0.1"
  @gateway_port 18789
  @gateway_path "/"
  @recheck_interval :timer.seconds(30)
  @initial_backoff 1_000
  @max_backoff 30_000
  defstruct [
    :conn,
    :ref,
    :websocket,
    :device_token,
    :tick_interval,
    :request_id_counter,
    :pending_requests,
    :last_error,
    :last_connected_at,
    :last_disconnected_at,
    status: :disconnected,
    backoff: @initial_backoff,
    reconnect_attempts: 0
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def device_id do
    GenServer.call(__MODULE__, :device_id)
  end

  def status_detail do
    GenServer.call(__MODULE__, :status_detail)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      request_id_counter: 0,
      pending_requests: %{}
    }

    schedule_connect_check()
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:status_detail, _from, state) do
    {:reply, %{
      status: state.status,
      last_error: state.last_error,
      last_connected_at: state.last_connected_at,
      last_disconnected_at: state.last_disconnected_at,
      reconnect_attempts: state.reconnect_attempts
    }, state}
  end

  def handle_call(:device_id, _from, state) do
    case Identity.ensure_keypair() do
      {:ok, %{public_key: pub}} -> {:reply, Identity.fingerprint(pub), state}
      _ -> {:reply, nil, state}
    end
  end

  @impl true
  def handle_info(:connect_check, state) do
    case readiness_state() do
      :ready ->
        case connect_to_gateway(state) do
          {:ok, new_state} ->
            Logger.info("[Node] Connecting to Gateway at #{@gateway_host}:#{@gateway_port}")
            broadcast(:connecting)

            {:noreply,
             %{new_state | status: :connecting, backoff: @initial_backoff, reconnect_attempts: 0}}

          {:error, reason} ->
            Logger.warning("[Node] Gateway connection failed: #{inspect(reason)}")
            schedule_reconnect(state.backoff)

            {:noreply,
             %{
               state
               | backoff: next_backoff(state.backoff),
                 last_error: "connect failed: #{inspect(reason)}",
                 reconnect_attempts: state.reconnect_attempts + 1,
                 last_disconnected_at: now_iso()
             }}
        end

      {:blocked, reason} ->
        schedule_connect_check()
        {:noreply, %{state | last_error: reason}}
    end
  end

  def handle_info(:heartbeat, %{status: :connected} = state) do
    case send_frame(state, :ping) do
      {:ok, new_state} ->
        schedule_heartbeat(state.tick_interval)
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, handle_disconnect(state, "heartbeat failed")}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    send(self(), :connect_check)
    {:noreply, state}
  end

  # Handle TCP/SSL messages from the Mint connection
  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_responses(responses, state)

      {:error, conn, reason, _responses} ->
        Logger.warning("[Node] Stream error: #{inspect(reason)}")
        {:noreply, handle_disconnect(%{state | conn: conn}, "stream error")}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn do
      send_frame(state, {:close, 1000, "shutting down"})
      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # --- Connection ---

  # Connect in passive mode for the HTTP upgrade, then read WebSocket frames
  # directly from the socket for the handshake. After the handshake completes,
  # switch to active mode for ongoing I/O.
  #
  # We can't use Mint.HTTP.recv after the upgrade because it tries to parse
  # WebSocket frames as HTTP and fails with {:unexpected_data, ...}. Instead
  # we read raw bytes from the socket and decode with Mint.WebSocket.decode.
  defp connect_to_gateway(state) do
    with {:ok, conn} <- Mint.HTTP.connect(:http, @gateway_host, @gateway_port, mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, @gateway_path, []),
         {:ok, conn, websocket, buffered_data} <- await_upgrade(conn, ref),
         state = %{state | conn: conn, ref: ref, websocket: websocket, status: :challenge},
         {:ok, state} <- process_buffered_or_recv(state, buffered_data),
         {:ok, state} <- recv_ws_and_process(state),
         {:ok, conn} <- Mint.HTTP.set_mode(state.conn, :active) do
      {:ok, %{state | conn: conn}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
      {:error, _conn, reason, _responses} -> {:error, reason}
    end
  end

  # Synchronously receive the HTTP 101 upgrade response and create the websocket.
  # The Gateway often sends the challenge in the same TCP segment as the 101
  # response, so we capture any {:data, ref, data} responses too.
  defp await_upgrade(conn, ref) do
    with {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, 5_000) do
      {status, headers, data_parts} =
        Enum.reduce(responses, {nil, [], []}, fn
          {:status, ^ref, s}, {_, h, d} -> {s, h, d}
          {:headers, ^ref, h}, {s, _, d} -> {s, h, d}
          {:data, ^ref, d}, {s, h, ds} -> {s, h, ds ++ [d]}
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

  # Process buffered data from the upgrade, or recv from socket if none.
  defp process_buffered_or_recv(state, nil), do: recv_ws_and_process(state)
  defp process_buffered_or_recv(state, data), do: process_ws_data(data, state)

  # Read raw bytes from the socket and decode as WebSocket frames.
  # After the HTTP upgrade, Mint.HTTP.recv can't parse WebSocket data,
  # so we bypass it and read directly from the TCP socket.
  defp recv_ws_and_process(state) do
    socket = Mint.HTTP.get_socket(state.conn)

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} ->
        process_ws_data(data, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_ws_data(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}

        Enum.reduce_while(frames, {:ok, state}, fn frame, {_, st} ->
          case handle_frame(frame, st) do
            {:ok, new_st} -> {:cont, {:ok, new_st}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, _websocket, reason} ->
        Logger.error("[Node] Decode error: #{inspect(reason)}")
        {:error, "websocket decode failed: #{inspect(reason)}"}
    end
  end

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {_, state} ->
      case handle_response(response, state) do
        {:ok, new_state} -> {:cont, {:noreply, new_state}}
        {:error, reason} -> {:halt, {:noreply, handle_disconnect(state, reason)}}
      end
    end)
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: ws} = state) when ws != nil do
    process_ws_data(data, state)
  end

  defp handle_response(_response, state), do: {:ok, state}

  # --- Frame handling ---

  defp handle_frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:event, "connect.challenge", %{"nonce" => nonce}} ->
        handle_challenge(nonce, state)

      {:res, id, true, payload} ->
        handle_ok_response(id, payload, state)

      {:res, id, false, error} ->
        handle_error_response(id, error, state)

      {:req, id, "node.invoke", params} ->
        handle_invoke(id, params, state)

      {:event, _name, _payload} ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[Node] Protocol decode error: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp handle_frame({:ping, data}, state) do
    send_frame(state, {:pong, data})
  end

  defp handle_frame({:pong, _data}, state), do: {:ok, state}

  defp handle_frame({:close, code, reason}, _state) do
    Logger.info("[Node] Server closed connection: #{code} #{reason}")
    {:error, "server closed: #{code}"}
  end

  defp handle_frame(_frame, state), do: {:ok, state}

  # --- Protocol handlers ---

  defp handle_challenge(nonce, state) do
    case Identity.ensure_keypair() do
      {:ok, %{public_key: pub, private_key: priv}} ->
        device_id = Identity.fingerprint(pub)
        signed_at = System.system_time(:millisecond)
        auth = gateway_auth()
        token = Map.get(auth, "token", "")

        # Gateway v3 signature: pipe-delimited payload with normalized metadata
        payload =
          Enum.join(
            [
              "v3",
              device_id,
              "node-host",
              "node",
              "node",
              "",
              to_string(signed_at),
              token || "",
              nonce,
              "linux",
              "pi"
            ],
            "|"
          )

        signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
        signature_b64 = Base.encode64(signature)

        {id, state} = next_request_id(state)

        connect_params = %{
          "minProtocol" => 3,
          "maxProtocol" => 3,
          "role" => "node",
          "scopes" => [],
          "auth" => auth,
          "client" => %{
            "id" => "node-host",
            "displayName" => "ClawRig",
            "version" => clawrig_version(),
            "platform" => "linux",
            "deviceFamily" => "pi",
            "mode" => "node"
          },
          "device" => %{
            "id" => device_id,
            "publicKey" => Base.encode64(pub),
            "signature" => signature_b64,
            "signedAt" => signed_at,
            "nonce" => nonce
          },
          "caps" => Capabilities.caps(),
          "commands" => Capabilities.commands(),
          "permissions" => Capabilities.permissions()
        }

        frame = Protocol.encode_request(to_string(id), "connect", connect_params)
        send_text(state, frame)

      {:error, reason} ->
        Logger.error("[Node] Identity error: #{inspect(reason)}")
        {:error, "identity error"}
    end
  end

  defp handle_ok_response(_id, %{"type" => "hello-ok"} = payload, state) do
    device_token = get_in(payload, ["auth", "deviceToken"])
    tick_interval = get_in(payload, ["policy", "tickIntervalMs"]) || 15_000

    Logger.info("[Node] Connected to Gateway (tick: #{tick_interval}ms)")
    broadcast(:connected)
    schedule_heartbeat(tick_interval)

    {:ok, %{state | status: :connected, device_token: device_token, tick_interval: tick_interval, last_error: nil, last_connected_at: now_iso(), reconnect_attempts: 0}}
  end

  defp handle_ok_response(_id, _payload, state), do: {:ok, state}

  defp handle_error_response(_id, %{"type" => "hello-error"} = error, _state) do
    Logger.error("[Node] Gateway rejected connection: #{inspect(error)}")
    {:error, "rejected: #{inspect(error)}"}
  end

  defp handle_error_response(_id, _error, state), do: {:ok, state}

  defp handle_invoke(id, %{"command" => command} = params, state) do
    Task.Supervisor.start_child(Clawrig.TaskSupervisor, fn ->
      result = Capabilities.invoke(command, Map.get(params, "params", %{}))

      response =
        case result do
          {:ok, data} ->
            Protocol.encode_response(id, true, data)

          {:error, reason} ->
            Protocol.encode_response(id, false, %{"reason" => to_string(reason)})
        end

      GenServer.cast(__MODULE__, {:send_frame, response})
    end)

    {:ok, state}
  end

  defp handle_invoke(id, _params, state) do
    response = Protocol.encode_response(id, false, %{"reason" => "missing command"})
    send_text(state, response)
  end

  @impl true
  def handle_cast({:send_frame, text}, state) do
    case send_text(state, text) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _} -> {:noreply, handle_disconnect(state, "send failed")}
    end
  end

  # --- Helpers ---

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, _reason} -> {:error, %{state | conn: conn, websocket: websocket}}
        end

      {:error, _websocket, reason} ->
        {:error, "websocket encode failed: #{inspect(reason)}"}
    end
  end

  defp send_text(state, text) do
    send_frame(state, {:text, text})
  end

  defp handle_disconnect(state, reason) do
    Logger.warning("[Node] Disconnected: #{reason}")
    broadcast(:disconnected)

    if state.conn, do: Mint.HTTP.close(state.conn)

    schedule_reconnect(state.backoff)

    %__MODULE__{
      status: :disconnected,
      backoff: next_backoff(state.backoff),
      request_id_counter: state.request_id_counter,
      pending_requests: %{},
      last_error: to_string(reason),
      last_connected_at: state.last_connected_at,
      last_disconnected_at: now_iso(),
      reconnect_attempts: state.reconnect_attempts + 1
    }
  end

  defp readiness_state do
    cond do
      not oobe_complete?() -> {:blocked, "waiting for OOBE completion"}
      not gateway_running?() -> {:blocked, "waiting for gateway to be running"}
      true -> :ready
    end
  end

  defp oobe_complete? do
    marker = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
    Application.get_env(:clawrig, :oobe_complete, File.exists?(marker))
  end

  defp gateway_running? do
    Commands.impl().gateway_status() == :running
  end

  defp next_request_id(state) do
    id = state.request_id_counter + 1
    {id, %{state | request_id_counter: id}}
  end

  defp next_backoff(current), do: min(current * 2, @max_backoff)

  defp schedule_connect_check do
    Process.send_after(self(), :connect_check, @recheck_interval)
  end

  defp schedule_reconnect(backoff) do
    Process.send_after(self(), :reconnect, backoff)
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp broadcast(status) do
    Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:node", {:node_status, status})
    Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:node", {:node_status_detail, status_detail()})
  end

  defp clawrig_version do
    case File.read("/opt/clawrig/VERSION") do
      {:ok, version} -> String.trim(version)
      _ -> "0.0.0-dev"
    end
  end


  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp gateway_auth do
    config_path = Path.expand("~/.openclaw/openclaw.json")

    case File.read(config_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"gateway" => %{"auth" => %{"token" => token}}}} -> %{"token" => token}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
