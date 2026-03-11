defmodule Clawrig.Gateway.OperatorClient do
  @moduledoc """
  Gateway-native operator client for the ClawRig chat surface.
  """

  use GenServer
  import Kernel, except: [send: 2]
  require Logger

  alias Clawrig.Gateway
  alias Clawrig.Gateway.OperatorStore
  alias Clawrig.Node.Protocol
  alias Clawrig.System.Commands

  @gateway_host "127.0.0.1"
  @gateway_port 18789
  @gateway_path "/"
  @recheck_interval :timer.seconds(15)
  @initial_backoff 1_000
  @max_backoff 30_000
  @operator_scopes ["operator.read", "operator.write", "operator.approvals"]
  @pairing_scopes @operator_scopes ++ ["operator.pairing"]
  @client_id "gateway-client"
  @client_mode "backend"

  defstruct [
    :transport,
    :tick_interval,
    :policy_snapshot,
    :last_error,
    :last_connected_at,
    :last_disconnected_at,
    :active_run_id,
    :pairing_error,
    request_id_counter: 0,
    pending_requests: %{},
    status: :unpaired,
    backoff: @initial_backoff,
    reconnect_attempts: 0
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def policy_snapshot do
    GenServer.call(__MODULE__, :policy_snapshot)
  end

  def history(session_key) do
    GenServer.call(__MODULE__, {:history, session_key}, 15_000)
  end

  def send(session_key, text, opts \\ []) do
    GenServer.call(__MODULE__, {:send, session_key, text, opts}, 15_000)
  end

  def abort(session_key, run_id \\ nil) do
    GenServer.call(__MODULE__, {:abort, session_key, run_id}, 15_000)
  end

  def resolve_approval(approval_id, decision, opts \\ []) do
    GenServer.call(__MODULE__, {:resolve_approval, approval_id, decision, opts}, 15_000)
  end

  def pair_local_admin do
    GenServer.call(__MODULE__, :pair_local_admin, 20_000)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{}
    Kernel.send(self(), :connect_check)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:policy_snapshot, _from, state), do: {:reply, state.policy_snapshot || %{}, state}

  def handle_call({:history, session_key}, _from, %{status: :connected} = state) do
    case send_request("chat.history", %{"sessionKey" => session_key}, :history, state) do
      {:ok, state} -> {:reply, {:ok, :pending}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:history, _session_key}, _from, state) do
    {:reply, {:error, status_error(state.status)}, state}
  end

  def handle_call({:send, session_key, text, opts}, _from, %{status: :connected} = state) do
    params = %{
      "sessionKey" => session_key,
      "message" => text,
      "idempotencyKey" => Keyword.get(opts, :idempotency_key, default_idempotency_key())
    }

    case send_request("chat.send", params, :send, state) do
      {:ok, state} ->
        {:reply, {:ok, :pending}, state}

      {:error, reason, state} ->
        Logger.warning("[Gateway.Operator] chat.send failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, _session_key, _text, _opts}, _from, state) do
    {:reply, {:error, status_error(state.status)}, state}
  end

  def handle_call({:abort, session_key, run_id}, _from, %{status: :connected} = state) do
    params =
      %{"sessionKey" => session_key}
      |> maybe_put("runId", run_id || state.active_run_id)

    case send_request("chat.abort", params, {:abort, session_key}, state) do
      {:ok, state} -> {:reply, {:ok, :pending}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abort, _session_key, _run_id}, _from, state) do
    {:reply, {:error, status_error(state.status)}, state}
  end

  def handle_call({:resolve_approval, approval_id, decision, opts}, _from, %{status: :connected} = state) do
    params = %{
      "approvalId" => approval_id,
      "decision" => decision,
      "reason" => Keyword.get(opts, :reason)
    }

    case send_request("exec.approval.resolve", compact_map(params), {:resolve_approval, approval_id}, state) do
      {:ok, state} -> {:reply, {:ok, :pending}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_approval, _approval_id, _decision, _opts}, _from, state) do
    {:reply, {:error, status_error(state.status)}, state}
  end

  def handle_call(:pair_local_admin, _from, state) do
    result = pair_locally(state)

    case result do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:connect_check, state) do
    case readiness_state() do
      :ready ->
        case connect_with_available_auth(state) do
          {:ok, state} ->
            {:noreply, state}

          {:error, :missing_auth, state} ->
            state = publish_status(%{state | status: :unpaired}, "Gateway auth is not configured")
            schedule_connect_check()
            {:noreply, state}

          {:error, _reason, state} ->
          schedule_connect_check()
          {:noreply, state}
        end

      {:blocked, detail} ->
        state = publish_status(%{state | status: :unavailable, last_error: detail}, detail)
        schedule_connect_check()
        {:noreply, state}
    end
  end

  def handle_info(:heartbeat, %{status: :connected, transport: transport} = state) when not is_nil(transport) do
    case transport_module().send_frame(transport, :ping) do
      {:ok, transport} ->
        schedule_heartbeat(state.tick_interval || 15_000)
        {:noreply, %{state | transport: transport}}

      {:error, transport, reason} ->
        {:noreply, disconnect(%{state | transport: transport}, reason)}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    Kernel.send(self(), :connect_check)
    {:noreply, state}
  end

  def handle_info(message, %{transport: transport} = state) when not is_nil(transport) do
    case transport_module().stream(transport, message) do
      {:ok, transport, frames} ->
        state = %{state | transport: transport}
        handle_frames(frames, state)

      {:error, transport, reason} ->
        {:noreply, disconnect(%{state | transport: transport}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport, do: transport_module().close(state.transport)
    :ok
  end

  defp handle_frames(frames, state) do
    Enum.reduce_while(frames, {:noreply, state}, fn frame, {_, state} ->
      case handle_frame(frame, state) do
        {:ok, state} -> {:cont, {:noreply, state}}
        {:disconnect, state} -> {:halt, {:noreply, state}}
      end
    end)
  end

  defp handle_frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:event, "chat", payload} ->
        Logger.debug("[Gateway.Operator] chat event: state=#{payload["state"]}, run=#{payload["runId"]}")
        {:ok, handle_chat_event(payload, state)}

      {:event, "agent", payload} ->
        {:ok, handle_agent_event(payload, state)}

      {:event, "exec.approval.requested", payload} ->
        broadcast_chat({:chat_approval_requested, normalize_approval(payload)})
        {:ok, state}

      {:event, "presence", _payload} ->
        {:ok, state}

      {:event, "health", payload} ->
        broadcast_status(state.status, payload)
        {:ok, state}

      {:event, "tick", _payload} ->
        {:ok, state}

      {:res, id, true, payload} ->
        {:ok, handle_ok_response(id, payload, state)}

      {:res, id, false, error} ->
        case handle_error_response(id, error, state) do
          {:ok, state} -> {:ok, state}
          {:disconnect, state} -> {:disconnect, state}
        end

      {:event, _name, _payload} ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[Gateway.Operator] Protocol decode error: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp handle_frame({:ping, data}, %{transport: transport} = state) do
    case transport_module().send_frame(transport, {:pong, data}) do
      {:ok, transport} -> {:ok, %{state | transport: transport}}
      {:error, transport, reason} -> {:disconnect, disconnect(%{state | transport: transport}, reason)}
    end
  end

  defp handle_frame({:pong, _data}, state), do: {:ok, state}

  defp handle_frame({:close, _code, reason}, state) do
    {:disconnect, disconnect(state, reason)}
  end

  defp handle_frame(_frame, state), do: {:ok, state}

  defp connect_with_available_auth(state) do
    shared_auth = shared_gateway_auth()
    device_token = OperatorStore.identity().device_token

    cond do
      map_size(shared_auth) == 0 and not (is_binary(device_token) and device_token != "") ->
        {:error, :missing_auth, %{state | status: :unpaired, last_error: "Gateway auth is not configured"}}

      is_binary(device_token) and device_token != "" ->
        auth = compact_map(Map.merge(shared_auth, %{"deviceToken" => device_token}))

        case connect_with_auth(state, auth) do
          {:ok, state} ->
            {:ok, state}

          {:error, _reason, state} ->
            OperatorStore.clear_device_token()
            connect_with_auth(state, shared_auth)
        end

      true ->
        connect_with_auth(state, shared_auth)
    end
  end

  defp connect_with_auth(state, auth) do
    with {:ok, transport, hello} <- handshake(auth, @operator_scopes),
         {:ok, transport} <- set_active(transport) do
      maybe_store_device_token(hello)

      state =
        state
        |> connected_state(transport, hello)
        |> publish_status("Gateway chat connected")

      Logger.info("[Gateway.Operator] Connected to Gateway (status=connected)")
      {:ok, state}
    else
      {:error, {:hello_error, error}} ->
        Logger.warning("[Gateway.Operator] Hello error: #{inspect(hello_reason(error))}")
        state = publish_status(%{state | status: :unpaired, last_error: hello_reason(error)}, hello_reason(error))
        {:error, hello_reason(error), state}

      {:error, reason} ->
        Logger.warning("[Gateway.Operator] Connection failed: #{inspect(reason)}")
        state = disconnect(state, reason)
        {:error, reason, state}
    end
  end

  defp pair_locally(state) do
    with :ready <- readiness_state(),
         auth when map_size(auth) > 0 <- shared_gateway_auth(),
         _ <- OperatorStore.clear_device_token(),
         {:ok, transport, hello} <- handshake(auth, @pairing_scopes),
         {:ok, transport} <- set_active(transport) do
      maybe_store_device_token(hello)

      state =
        state
        |> connected_state(transport, hello)
        |> publish_status("Gateway pairing complete")

      {:ok, state}
    else
      {:blocked, detail} ->
        state = publish_status(%{state | status: :unavailable, last_error: detail}, detail)
        {:error, detail, state}

      auth when is_map(auth) and map_size(auth) == 0 ->
        detail = "Gateway shared auth is not configured"
        state = publish_status(%{state | status: :unpaired, last_error: detail}, detail)
        {:error, detail, state}

      {:error, reason} ->
        detail = hello_reason(reason)
        state = publish_status(%{state | status: :unpaired, last_error: detail}, detail)
        {:error, detail, state}
    end
  end

  defp handshake(auth, scopes) do
    with {:ok, transport, buffered_data} <- transport_module().connect(@gateway_host, @gateway_port, @gateway_path),
         {:ok, transport, hello} <- handshake_frames(transport, buffered_data, auth, scopes) do
      {:ok, transport, hello}
    end
  end

  defp handshake_frames(transport, nil, auth, scopes) do
    with {:ok, transport, frames} <- transport_module().recv(transport),
         {:ok, transport, hello} <- consume_handshake_frames(transport, frames, auth, scopes) do
      {:ok, transport, hello}
    end
  end

  defp handshake_frames(transport, data, auth, scopes) do
    with {:ok, transport, frames} <- transport_module().decode(transport, data),
         {:ok, transport, hello} <- consume_handshake_frames(transport, frames, auth, scopes) do
      {:ok, transport, hello}
    end
  end

  defp consume_handshake_frames(transport, frames, auth, scopes) do
    Enum.reduce_while(frames, {:continue, transport}, fn frame, {:continue, transport} ->
      case frame do
        {:text, text} ->
          case Protocol.decode(text) do
            {:event, "connect.challenge", %{"nonce" => nonce}} ->
              case send_connect(transport, nonce, auth, scopes) do
                {:ok, transport} -> {:cont, {:continue, transport}}
                {:error, transport, reason} -> {:halt, {:error, reason, transport}}
              end

            {:res, _id, true, %{"type" => "hello-ok"} = payload} ->
              {:halt, {:ok, transport, payload}}

            {:res, _id, false, %{"type" => "hello-error"} = payload} ->
              {:halt, {:error, {:hello_error, payload}}}

            _ ->
              {:cont, {:continue, transport}}
          end

        {:ping, data} ->
          case transport_module().send_frame(transport, {:pong, data}) do
            {:ok, transport} -> {:cont, {:continue, transport}}
            {:error, _transport, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:cont, {:continue, transport}}
      end
    end)
    |> case do
      {:ok, transport, payload} ->
        {:ok, transport, payload}

      {:error, reason, transport} ->
        transport_module().close(transport)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      {:continue, transport} ->
        handshake_frames(transport, nil, auth, scopes)
    end
  end

  defp send_connect(transport, nonce, auth, scopes) do
    identity = OperatorStore.identity()
    signed_at = System.system_time(:millisecond)
    auth_token = Map.get(auth, "token") || Map.get(auth, "deviceToken") || ""

    payload =
      Enum.join(
        [
          "v3",
          identity.device_id,
          @client_id,
          @client_mode,
          "operator",
          Enum.join(scopes, ","),
          to_string(signed_at),
          auth_token,
          nonce,
          "linux",
          "pi"
        ],
        "|"
      )

    signature =
      :crypto.sign(:eddsa, :none, payload, [identity.private_key, :ed25519])
      |> Base.url_encode64(padding: false)

    params = %{
      "minProtocol" => 3,
      "maxProtocol" => 3,
      "role" => "operator",
      "scopes" => scopes,
      "auth" => auth,
      "client" => %{
        "id" => @client_id,
        "displayName" => "ClawRig Chat",
        "version" => clawrig_version(),
        "platform" => "linux",
        "deviceFamily" => "pi",
        "mode" => @client_mode
      },
      "caps" => [],
      "device" => %{
        "id" => identity.device_id,
        "publicKey" => Base.url_encode64(identity.public_key, padding: false),
        "signature" => signature,
        "signedAt" => signed_at,
        "nonce" => nonce
      }
    }

    frame = Protocol.encode_request("connect-1", "connect", params)
    transport_module().send_frame(transport, {:text, frame})
  end

  defp set_active(transport) do
    case transport_module().set_mode(transport, :active) do
      {:ok, transport} -> {:ok, transport}
      {:error, _transport, reason} -> {:error, reason}
    end
  end

  defp connected_state(state, transport, hello) do
    tick_interval = get_in(hello, ["policy", "tickIntervalMs"]) || 15_000
    schedule_heartbeat(tick_interval)

    %{
      state
      | transport: transport,
        tick_interval: tick_interval,
        policy_snapshot: %{
          "auth" => get_in(hello, ["auth"]) || %{},
          "policy" => get_in(hello, ["policy"]) || %{},
          "methods" => get_in(hello, ["methods"]) || [],
          "events" => get_in(hello, ["events"]) || []
        },
        status: :connected,
        backoff: @initial_backoff,
        reconnect_attempts: 0,
        last_error: nil,
        pairing_error: nil,
        last_connected_at: now_iso()
    }
  end

  defp send_request(method, params, request_type, %{transport: transport} = state) do
    {id, state} = next_request_id(state)
    frame = Protocol.encode_request(id, method, params)

    case transport_module().send_frame(transport, {:text, frame}) do
      {:ok, transport} ->
        state =
          %{state | transport: transport}
          |> put_pending_request(id, request_type)

        {:ok, state}

      {:error, transport, reason} ->
        {:error, reason, disconnect(%{state | transport: transport}, reason)}
    end
  end

  defp put_pending_request(state, id, request_type) do
    pending = Map.put(state.pending_requests, id, request_type)
    %{state | pending_requests: pending}
  end

  defp handle_ok_response("connect-1", %{"type" => "hello-ok"}, state), do: state

  defp handle_ok_response(id, payload, state) do
    case Map.pop(state.pending_requests, id) do
      {:history, pending_requests} ->
        {messages, meta} = normalize_history(payload)
        session_key = meta["sessionKey"] || Gateway.session_key()
        broadcast_chat({:chat_history, session_key, messages, meta})
        %{state | pending_requests: pending_requests}

      {:send, pending_requests} ->
        run_id = payload["runId"] || payload["id"] || payload["requestId"]
        %{state | pending_requests: pending_requests, active_run_id: run_id}

      {{:abort, session_key}, pending_requests} ->
        broadcast_chat({:chat_aborted, session_key, state.active_run_id})
        %{state | pending_requests: pending_requests, active_run_id: nil}

      {{:resolve_approval, approval_id}, pending_requests} ->
        decision = payload["decision"] || payload["status"] || "resolved"
        broadcast_chat({:chat_approval_resolved, approval_id, decision})
        %{state | pending_requests: pending_requests}

      {nil, _pending_requests} ->
        state
    end
  end

  defp handle_error_response(id, error, state) do
    case Map.pop(state.pending_requests, id) do
      {{:abort, session_key}, pending_requests} ->
        broadcast_chat({:chat_error, session_key, hello_reason(error)})
        {:ok, %{state | pending_requests: pending_requests}}

      {{:resolve_approval, approval_id}, pending_requests} ->
        broadcast_chat({:chat_error, approval_id, hello_reason(error)})
        {:ok, %{state | pending_requests: pending_requests}}

      {request_type, pending_requests} when request_type in [:history, :send] ->
        Logger.warning("[Gateway.Operator] Error response for #{request_type}: #{inspect(error)}")
        broadcast_chat({:chat_error, request_type, hello_reason(error)})
        {:ok, %{state | pending_requests: pending_requests}}

      {nil, _pending_requests} ->
        if match?(%{"type" => "hello-error"}, error) do
          {:disconnect, disconnect(state, hello_reason(error))}
        else
          {:ok, state}
        end
    end
  end

  # Chat events use: "state" => "delta" | "final", no message content
  # Agent events carry the actual content via "stream" and "data" keys
  # We use chat events only as a fallback signal — agent events are primary
  defp handle_chat_event(payload, state) do
    chat_state = payload["state"]
    session_key = payload["sessionKey"] || Gateway.session_key()
    run_id = payload["runId"] || state.active_run_id

    case chat_state do
      "final" ->
        # Only finalize if agent lifecycle.end hasn't already done so
        if state.active_run_id do
          message = normalize_message(payload["message"] || %{"content" => "", "role" => "assistant"})
          broadcast_chat({:chat_done, session_key, run_id, message})
          %{state | active_run_id: nil}
        else
          state
        end

      "aborted" ->
        broadcast_chat({:chat_aborted, session_key, run_id})
        %{state | active_run_id: nil}

      "error" ->
        broadcast_chat({:chat_error, session_key, payload["reason"] || "Chat error"})
        %{state | active_run_id: nil}

      # "delta" and other states — agent events handle content, skip here
      _ ->
        state
    end
  end

  # Agent events use: "stream" => "lifecycle" | "assistant", "data" => %{...}
  defp handle_agent_event(payload, state) do
    stream = payload["stream"]
    data = payload["data"] || %{}
    session_key = payload["sessionKey"] || Gateway.session_key()
    run_id = payload["runId"] || state.active_run_id

    case {stream, data["phase"]} do
      {"assistant", _} ->
        chunk = data["delta"] || ""

        if chunk != "" do
          broadcast_chat({:chat_delta, session_key, run_id, chunk})
        end

        %{state | active_run_id: run_id}

      {"lifecycle", "end"} ->
        # Mark run finished but do NOT broadcast chat_done here.
        # The chat "final" event handles completion to avoid duplicates.
        # Clear active_run_id so chat handler knows this run ended.
        state

      {"lifecycle", "start"} ->
        %{state | active_run_id: run_id}

      {"lifecycle", "error"} ->
        broadcast_chat({:chat_error, session_key, data["reason"] || "Agent error"})
        %{state | active_run_id: nil}

      {"lifecycle", "aborted"} ->
        broadcast_chat({:chat_aborted, session_key, run_id})
        %{state | active_run_id: nil}

      _ ->
        state
    end
  end

  defp normalize_history(payload) do
    messages =
      Enum.find_value(["messages", "items", "entries", "history"], [], fn key ->
        case payload[key] do
          list when is_list(list) ->
            list
            |> Enum.reject(&raw_api_message?/1)
            |> Enum.map(&normalize_message/1)
          _ -> nil
        end
      end)

    meta =
      payload
      |> Map.drop(["messages", "items", "entries", "history"])
      |> Map.put_new("sessionKey", payload["sessionKey"] || Gateway.session_key())

    {messages, meta}
  end

  defp normalize_message(message) when is_map(message) do
    role = message["role"] || message["author"] || message["sender"] || "assistant"

    %{
      id: message["id"] || message["messageId"] || unique_id("gateway-msg"),
      kind: :message,
      role: role,
      content: extract_text(message),
      streaming: false,
      status: normalize_message_status(message),
      run_id: message["runId"]
    }
  end

  defp normalize_message(message) when is_binary(message) do
    %{
      id: unique_id("gateway-msg"),
      kind: :message,
      role: "assistant",
      content: message,
      streaming: false,
      status: "done",
      run_id: nil
    }
  end

  defp broadcastable_live_message?(message) do
    message.role not in ["user", "toolResult"] and String.trim(message.content || "") != ""
  end

  # Gateway history returns two assistant entries per turn:
  # 1. Raw API response with thinking/tool_use blocks or textSignature fields
  # 2. Clean display-only version with just type: "text"
  # Filter out the raw version to avoid duplicates.
  defp raw_api_message?(%{"role" => "assistant", "content" => content}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "thinking"} -> true
      %{"type" => "tool_use"} -> true
      %{"textSignature" => _} -> true
      _ -> false
    end)
  end

  defp raw_api_message?(_), do: false

  defp normalize_approval(payload) do
    %{
      id: payload["approvalId"] || payload["id"] || unique_id("approval"),
      kind: :approval,
      title: payload["title"] || payload["label"] || "Approval requested",
      detail: payload["detail"] || payload["reason"] || payload["summary"] || "The agent needs approval to continue.",
      status: "pending",
      raw: payload
    }
  end

  defp normalize_message_status(message) do
    message["status"] || message["state"] || "done"
  end

  defp extract_text(message) do
    cond do
      is_binary(message["text"]) ->
        message["text"]

      is_binary(message["content"]) ->
        message["content"]

      is_list(message["content"]) ->
        message["content"]
        |> Enum.map(fn
          %{"type" => "text", "text" => text} -> text
          %{"text" => text} -> text
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("")

      is_map(message["message"]) ->
        extract_text(message["message"])

      true ->
        ""
    end
  end

  defp disconnect(state, reason) do
    if state.transport, do: transport_module().close(state.transport)
    Logger.warning("[Gateway.Operator] Disconnected: #{inspect(reason)}")

    detail = hello_reason(reason)
    new_status = if OperatorStore.identity().device_token, do: :connecting, else: :unpaired
    state = %{
      state
      | transport: nil,
        policy_snapshot: nil,
        active_run_id: nil,
        last_error: detail,
        last_disconnected_at: now_iso(),
        reconnect_attempts: state.reconnect_attempts + 1,
        backoff: next_backoff(state.backoff),
        status: new_status
    }

    state
    |> publish_status(detail)
    |> tap(fn _ -> schedule_reconnect(state.backoff) end)
  end

  defp publish_status(state, detail) do
    broadcast_status(state.status, %{
      last_error: state.last_error,
      detail: detail,
      last_connected_at: state.last_connected_at,
      last_disconnected_at: state.last_disconnected_at,
      reconnect_attempts: state.reconnect_attempts
    })

    state
  end

  defp broadcast_status(status, detail) do
    Phoenix.PubSub.broadcast(Clawrig.PubSub, Gateway.operator_topic(), {:operator_status, status, detail})
  end

  defp broadcast_chat(event) do
    session_key =
      case event do
        {:chat_history, session_key, _messages, _meta} -> session_key
        {:chat_delta, session_key, _run_id, _chunk} -> session_key
        {:chat_done, session_key, _run_id, _message} -> session_key
        {:chat_aborted, session_key, _run_id} -> session_key
        {:chat_error, session_key, _reason} when is_binary(session_key) -> session_key
        _ -> Gateway.session_key()
      end

    Phoenix.PubSub.broadcast(Clawrig.PubSub, Gateway.chat_topic(session_key), event)
  end

  defp readiness_state do
    cond do
      not oobe_complete?() -> {:blocked, "Waiting for setup to finish"}
      not gateway_running?() -> {:blocked, "Waiting for the OpenClaw Gateway"}
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
    id = Integer.to_string(state.request_id_counter + 1)
    {id, %{state | request_id_counter: state.request_id_counter + 1}}
  end

  defp default_idempotency_key do
    unique_id("clawrig")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp shared_gateway_auth do
    config_path = shared_auth_path()

    with {:ok, json} <- File.read(config_path),
         {:ok, config} <- Jason.decode(json),
         %{"gateway" => gateway} <- config,
         %{"auth" => auth} <- gateway do
      auth
      |> Map.take(["token", "password"])
      |> compact_map()
    else
      _ -> %{}
    end
  end

  defp schedule_connect_check do
    Process.send_after(self(), :connect_check, @recheck_interval)
  end

  defp schedule_reconnect(backoff) do
    Process.send_after(self(), :reconnect, backoff)
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp next_backoff(current), do: min(max(current, @initial_backoff) * 2, @max_backoff)

  defp status_error(:connected), do: :ok
  defp status_error(:unpaired), do: :unpaired
  defp status_error(:unavailable), do: :unavailable
  defp status_error(:connecting), do: :connecting
  defp status_error(_), do: :disconnected

  defp hello_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp hello_reason(%{"code" => code}) when is_binary(code), do: code
  defp hello_reason(reason) when is_binary(reason), do: reason
  defp hello_reason(reason), do: inspect(reason)

  defp maybe_store_device_token(hello) do
    case get_in(hello, ["auth", "deviceToken"]) do
      device_token when is_binary(device_token) and device_token != "" ->
        OperatorStore.put_device_token(device_token)

      _ ->
        :ok
    end
  end

  defp transport_module do
    Application.get_env(:clawrig, :gateway_transport, Clawrig.Gateway.Transport)
  end

  defp shared_auth_path do
    Application.get_env(
      :clawrig,
      :gateway_shared_auth_path,
      Path.expand("~/.openclaw/openclaw.json")
    )
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

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
