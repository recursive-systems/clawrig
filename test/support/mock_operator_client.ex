defmodule Clawrig.Gateway.MockOperatorClient do
  @moduledoc false

  use GenServer

  alias Clawrig.Gateway

  defstruct status: :unpaired, policy_snapshot: %{}, history: %{}, run_seq: 0, pair_result: :ok

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
    GenServer.call(__MODULE__, {:history, session_key})
  end

  def send(session_key, text, _opts \\ []) do
    GenServer.call(__MODULE__, {:send, session_key, text})
  end

  def abort(session_key, run_id \\ nil) do
    GenServer.call(__MODULE__, {:abort, session_key, run_id})
  end

  def resolve_approval(approval_id, decision, _opts \\ []) do
    GenServer.call(__MODULE__, {:resolve_approval, approval_id, decision})
  end

  def pair_local_admin do
    GenServer.call(__MODULE__, :pair_local_admin)
  end

  def set_pair_result(result) do
    GenServer.call(__MODULE__, {:set_pair_result, result})
  end

  def set_status(status) do
    GenServer.call(__MODULE__, {:set_status, status})
  end

  def seed_history(messages, session_key \\ Gateway.session_key()) do
    GenServer.call(__MODULE__, {:seed_history, session_key, messages})
  end

  def emit(event, session_key \\ Gateway.session_key()) do
    topic = if match?({:operator_status, _, _}, event), do: Gateway.operator_topic(), else: Gateway.chat_topic(session_key)
    Phoenix.PubSub.broadcast(Clawrig.PubSub, topic, event)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:policy_snapshot, _from, state), do: {:reply, state.policy_snapshot, state}
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  def handle_call({:set_pair_result, result}, _from, state) do
    {:reply, :ok, %{state | pair_result: result}}
  end

  def handle_call({:set_status, status}, _from, state) do
    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.operator_topic(),
      {:operator_status, status, %{detail: "mock"}}
    )

    {:reply, :ok, %{state | status: status}}
  end

  def handle_call({:seed_history, session_key, messages}, _from, state) do
    history = Map.put(state.history, session_key, messages)
    {:reply, :ok, %{state | history: history}}
  end

  def handle_call({:history, session_key}, _from, state) do
    messages = Map.get(state.history, session_key, [])

    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.chat_topic(session_key),
      {:chat_history, session_key, messages, %{"sessionKey" => session_key}}
    )

    {:reply, {:ok, messages}, state}
  end

  def handle_call({:send, session_key, text}, _from, state) do
    run_id = Integer.to_string(state.run_seq + 1)

    Process.send_after(
      self(),
      {:emit_delta, session_key, run_id, "Mock response to: #{text}"},
      20
    )

    Process.send_after(
      self(),
      {:emit_done, session_key, run_id, "Mock response to: #{text}"},
      120
    )

    {:reply, {:ok, %{"runId" => run_id}}, %{state | status: :connected, run_seq: state.run_seq + 1}}
  end

  def handle_call({:abort, session_key, run_id}, _from, state) do
    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.chat_topic(session_key),
      {:chat_aborted, session_key, run_id}
    )

    {:reply, {:ok, %{}}, state}
  end

  def handle_call({:resolve_approval, approval_id, decision}, _from, state) do
    resolved =
      case decision do
        "approve" -> "approved"
        "deny" -> "denied"
        other -> other
      end

    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.chat_topic(),
      {:chat_approval_resolved, approval_id, resolved}
    )

    {:reply, {:ok, %{"decision" => resolved}}, state}
  end

  def handle_call(:pair_local_admin, _from, state) do
    case state.pair_result do
      :ok ->
        Phoenix.PubSub.broadcast(
          Clawrig.PubSub,
          Gateway.operator_topic(),
          {:operator_status, :connected, %{detail: "mock paired"}}
        )

        {:reply, :ok, %{state | status: :connected, policy_snapshot: %{"mock" => true}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:emit_delta, session_key, run_id, chunk}, state) do
    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.chat_topic(session_key),
      {:chat_delta, session_key, run_id, chunk}
    )

    {:noreply, state}
  end

  def handle_info({:emit_done, session_key, run_id, content}, state) do
    Phoenix.PubSub.broadcast(
      Clawrig.PubSub,
      Gateway.chat_topic(session_key),
      {:chat_done,
       session_key,
       run_id,
       %{id: "assistant-#{run_id}", kind: :message, role: "assistant", content: content, streaming: false, status: "done", run_id: run_id}}
    )

    {:noreply, state}
  end
end
