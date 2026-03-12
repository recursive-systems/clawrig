defmodule Clawrig.Wizard.State do
  use GenServer

  @default_state %{
    schema_version: 1,
    phase: :wifi_provisioning,
    step: :preflight,
    mode: :new,
    wifi_configured: false,
    network_method: nil,
    preflight_done: false,
    provider_done: false,
    tg_token: nil,
    tg_chat_id: nil,
    tg_bot_name: nil,
    tg_bot_username: nil,
    tg_nonce: nil,
    tg_baseline_update_id: nil,
    local_ip: nil,
    provider_type: nil,
    provider_name: nil,
    provider_base_url: nil,
    provider_model_id: nil,
    provider_auth_method: nil,
    openai_device_auth_id: nil,
    openai_user_code: nil,
    dashboard_auth_done: false,
    update_resume_version: nil,
    update_resume_reason: nil,
    update_retry_attempts: 0,
    update_history: [],
    auto_update_enabled: true,
    diagnostics_dry_run: true,
    update_channel: "stable"
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

    # Atomic write: write to tmp then rename to prevent corruption on power loss
    tmp = "#{path}.tmp"
    File.write!(tmp, json)
    File.rename!(tmp, path)
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
    data = data |> migrate_schema() |> migrate_legacy_fields()

    Map.new(@default_state, fn {k, default} ->
      str_key = to_string(k)

      value =
        case Map.get(data, str_key) do
          nil ->
            default

          v when k in [:phase, :step, :mode, :network_method] and is_binary(v) ->
            v |> migrate_step_value() |> String.to_existing_atom()

          v ->
            v
        end

      {k, value}
    end)
  rescue
    ArgumentError -> nil
  end

  defp migrate_schema(%{"schema_version" => v} = data) when v >= 1, do: data

  defp migrate_schema(data) do
    # v0 -> v1: stamp schema version (no field changes needed)
    Map.put(data, "schema_version", 1)
  end

  defp migrate_step_value("openai"), do: "provider"
  defp migrate_step_value(v), do: v

  defp migrate_legacy_fields(data) do
    data
    |> migrate_field("openai_done", "provider_done")
    |> migrate_field("openai_auth_method", "provider_auth_method")
  end

  defp migrate_field(data, old_key, new_key) do
    if Map.has_key?(data, old_key) and not Map.has_key?(data, new_key) do
      data |> Map.put(new_key, Map.get(data, old_key)) |> Map.delete(old_key)
    else
      data
    end
  end
end
