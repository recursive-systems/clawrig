defmodule Clawrig.Wizard.State do
  use GenServer

  @default_state %{
    phase: :wifi_provisioning,
    step: :preflight,
    mode: :new,
    wifi_configured: false,
    preflight_done: false,
    install_done: false,
    install_version: nil,
    oauth_tokens: nil,
    tg_token: nil,
    tg_chat_id: nil,
    tg_bot_name: nil,
    tg_bot_username: nil,
    local_ip: nil,
    launch_done: false,
    verify_passed: false,
    launch_items: nil,
    launch_messages: nil
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def get, do: GenServer.call(__MODULE__, :get)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def merge(map), do: GenServer.call(__MODULE__, {:merge, map})
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_) do
    state = load_from_disk() || @default_state
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call({:put, key, value}, _from, state) do
    new_state = Map.put(state, key, value)
    persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:merge, map}, _from, state) do
    new_state = Map.merge(state, map)
    persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, _state) do
    persist(@default_state)
    {:reply, :ok, @default_state}
  end

  defp state_path do
    Application.get_env(:clawrig, :state_path, "wizard-state.json")
  end

  defp persist(state) do
    path = state_path()

    case Path.dirname(path) do
      "." -> :ok
      dir -> File.mkdir_p!(dir)
    end

    json =
      state
      |> stringify_keys()
      |> Jason.encode!(pretty: true)

    File.write!(path, json)
  end

  defp load_from_disk do
    path = state_path()

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, data} -> atomize_state(data)
        _ -> nil
      end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(v), do: v

  defp atomize_state(data) when is_map(data) do
    Map.new(@default_state, fn {k, default} ->
      str_key = to_string(k)

      value =
        case Map.get(data, str_key) do
          nil ->
            default

          v when k in [:phase, :step, :mode] and is_binary(v) ->
            String.to_existing_atom(v)

          v when k in [:launch_items] and is_map(v) ->
            Map.new(v, fn {mk, mv} ->
              {String.to_existing_atom(mk), String.to_existing_atom(mv)}
            end)

          v when k in [:launch_messages] and is_map(v) ->
            Map.new(v, fn {mk, mv} ->
              {String.to_existing_atom(mk), mv}
            end)

          v ->
            v
        end

      {k, value}
    end)
  rescue
    ArgumentError -> nil
  end
end
