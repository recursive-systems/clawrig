defmodule Clawrig.Wifi.Manager do
  use GenServer

  require Logger

  alias Clawrig.System.Commands

  @default_connect_timeout_ms 120_000

  defstruct [
    :mode,
    :networks,
    :connecting,
    :connected_ssid,
    :last_error,
    :connect_attempt_ref,
    :connect_timer_ref,
    :connect_task_pid
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def scan, do: GenServer.call(__MODULE__, :scan, 15_000)
  def networks, do: GenServer.call(__MODULE__, :networks)
  def connect(ssid, password), do: GenServer.call(__MODULE__, {:connect, ssid, password}, 30_000)

  def safe_connect(ssid, password),
    do: GenServer.cast(__MODULE__, {:safe_connect, ssid, password})

  def start_hotspot, do: GenServer.call(__MODULE__, :start_hotspot, 15_000)
  def stop_hotspot, do: GenServer.call(__MODULE__, :stop_hotspot, 15_000)
  def status, do: GenServer.call(__MODULE__, :status, 10_000)

  @impl true
  def init(_) do
    {:ok,
     %__MODULE__{
       mode: :idle,
       networks: [],
       connecting: false,
       connected_ssid: nil,
       last_error: nil,
       connect_attempt_ref: nil,
       connect_timer_ref: nil,
       connect_task_pid: nil
     }}
  end

  @impl true
  def handle_call(:scan, _from, state) do
    networks = Commands.impl().scan_networks()

    # nmcli may return empty in AP mode; fall back to cached results.
    networks = if networks == [], do: state.networks, else: networks

    {:reply, {:ok, networks}, %{state | networks: networks}}
  end

  def handle_call(:networks, _from, state) do
    {:reply, state.networks, state}
  end

  def handle_call({:connect, ssid, password}, _from, state) do
    case Commands.impl().connect_wifi(ssid, password) do
      {:ok, ip} ->
        if ip, do: Clawrig.Wizard.State.put(:local_ip, ip)
        {:reply, :ok, %{state | mode: :station, connecting: false, connected_ssid: ssid}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | connecting: false, last_error: error_string(reason)}}
    end
  end

  def handle_call(:start_hotspot, _from, state) do
    case Commands.impl().start_hotspot() do
      :ok -> {:reply, :ok, %{state | mode: :ap}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop_hotspot, _from, state) do
    Commands.impl().stop_hotspot()
    {:reply, :ok, %{state | mode: :idle}}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       mode: state.mode,
       connected_ssid: state.connected_ssid,
       connecting: state.connecting,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_cast({:safe_connect, _ssid, _password}, %{connecting: true} = state) do
    # Ignore duplicate connect requests while a connect attempt is already in progress.
    {:noreply, state}
  end

  def handle_cast({:safe_connect, ssid, password}, state) do
    parent = self()
    attempt_ref = make_ref()

    timeout_ms =
      Application.get_env(:clawrig, :wifi_connect_timeout_ms, @default_connect_timeout_ms)

    case Task.Supervisor.start_child(Clawrig.TaskSupervisor, fn ->
           # Must tear down AP before wlan0 can join a network.
           _ = Commands.impl().stop_hotspot()

           result =
             case Commands.impl().connect_wifi(ssid, password) do
               {:ok, ip} -> {:ok, ip}
               {:error, reason} -> {:error, reason}
             end

           send(parent, {:safe_connect_result, attempt_ref, ssid, result})
         end) do
      {:ok, task_pid} ->
        timer_ref =
          Process.send_after(parent, {:safe_connect_timeout, attempt_ref, ssid}, timeout_ms)

        # Shift out of AP mode immediately so browser routes are not forced back to
        # /portal while connection is in-flight.
        {:noreply,
         %{
           state
           | mode: :idle,
             connecting: true,
             last_error: nil,
             connect_attempt_ref: attempt_ref,
             connect_task_pid: task_pid,
             connect_timer_ref: timer_ref
         }}

      {:error, reason} ->
        Logger.warning("Failed to start safe_connect task for #{ssid}: #{inspect(reason)}")
        _ = Commands.impl().start_hotspot()

        {:noreply,
         %{
           state
           | mode: :ap,
             connecting: false,
             last_error: "failed_to_start_connect_task"
         }}
    end
  end

  @impl true
  def handle_info(
        {:safe_connect_result, ref, ssid, {:ok, ip}},
        %{connect_attempt_ref: ref} = state
      ) do
    state = clear_connect_tracking(state)
    Logger.info("Connected to #{ssid} (#{ip})")
    if ip, do: Clawrig.Wizard.State.put(:local_ip, ip)
    Clawrig.Wizard.State.put(:wifi_configured, true)

    # Persist preflight connectivity so setup can continue immediately after
    # successful Wi-Fi onboarding without waiting on a separate trigger.
    Clawrig.Wizard.State.put(:preflight_done, Commands.impl().check_internet())

    current_method = Clawrig.Wizard.State.get(:network_method)
    method = if current_method == :ethernet, do: :both, else: :wifi
    Clawrig.Wizard.State.put(:network_method, method)

    {:noreply,
     %{state | mode: :station, connecting: false, connected_ssid: ssid, last_error: nil}}
  end

  def handle_info(
        {:safe_connect_result, ref, ssid, {:error, reason}},
        %{connect_attempt_ref: ref} = state
      ) do
    state = clear_connect_tracking(state)
    Logger.warning("WiFi connect to #{ssid} failed: #{inspect(reason)}, restarting hotspot")
    _ = Commands.impl().start_hotspot()

    {:noreply,
     %{
       state
       | mode: :ap,
         connecting: false,
         connected_ssid: nil,
         last_error: error_string(reason)
     }}
  end

  def handle_info({:safe_connect_timeout, ref, ssid}, %{connect_attempt_ref: ref} = state) do
    Logger.warning("WiFi connect to #{ssid} timed out, restarting hotspot")

    if is_pid(state.connect_task_pid) do
      _ = Task.Supervisor.terminate_child(Clawrig.TaskSupervisor, state.connect_task_pid)
    end

    {mode, error} =
      case Commands.impl().start_hotspot() do
        :ok ->
          {:ap, "connect_timeout"}

        {:error, reason} ->
          Logger.error("Hotspot restart failed after timeout: #{inspect(reason)}, retrying...")
          Process.sleep(2_000)

          case Commands.impl().start_hotspot() do
            :ok ->
              {:ap, "connect_timeout"}

            {:error, reason2} ->
              Logger.error("Hotspot retry also failed: #{inspect(reason2)}")
              {:idle, "connect_timeout_no_hotspot"}
          end
      end

    {:noreply,
     %{
       state
       | mode: mode,
         connecting: false,
         connected_ssid: nil,
         last_error: error,
         connect_attempt_ref: nil,
         connect_task_pid: nil,
         connect_timer_ref: nil
     }}
  end

  # Stale result/timeout from a previous attempt; ignore.
  def handle_info({:safe_connect_result, _ref, _ssid, _result}, state), do: {:noreply, state}
  def handle_info({:safe_connect_timeout, _ref, _ssid}, state), do: {:noreply, state}

  defp clear_connect_tracking(state) do
    if state.connect_timer_ref do
      _ = Process.cancel_timer(state.connect_timer_ref)
    end

    %{state | connect_attempt_ref: nil, connect_task_pid: nil, connect_timer_ref: nil}
  end

  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: inspect(reason)
end
