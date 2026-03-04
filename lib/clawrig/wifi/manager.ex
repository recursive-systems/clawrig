defmodule Clawrig.Wifi.Manager do
  use GenServer

  alias Clawrig.System.Commands

  defstruct [:mode, :networks, :connecting, :connected_ssid]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def scan, do: GenServer.call(__MODULE__, :scan, 15_000)
  def networks, do: GenServer.call(__MODULE__, :networks)
  def connect(ssid, password), do: GenServer.call(__MODULE__, {:connect, ssid, password}, 30_000)

  def safe_connect(ssid, password),
    do: GenServer.cast(__MODULE__, {:safe_connect, ssid, password})

  def start_hotspot, do: GenServer.call(__MODULE__, :start_hotspot)
  def stop_hotspot, do: GenServer.call(__MODULE__, :stop_hotspot)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_) do
    {:ok, %__MODULE__{mode: :idle, networks: [], connecting: false, connected_ssid: nil}}
  end

  @impl true
  def handle_call(:scan, _from, %{mode: :ap} = state) do
    # Can't scan while wlan0 is in AP mode — return cached or empty list
    {:reply, {:ok, state.networks}, state}
  end

  def handle_call(:scan, _from, state) do
    networks = Commands.impl().scan_networks()
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
        {:reply, {:error, reason}, %{state | connecting: false}}
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
    {:reply, %{mode: state.mode, connected_ssid: state.connected_ssid}, state}
  end

  @impl true
  def handle_cast({:safe_connect, ssid, password}, state) do
    require Logger

    # Must tear down AP before wlan0 can join a network
    Commands.impl().stop_hotspot()

    case Commands.impl().connect_wifi(ssid, password) do
      {:ok, ip} ->
        Logger.info("Connected to #{ssid} (#{ip})")
        if ip, do: Clawrig.Wizard.State.put(:local_ip, ip)
        Clawrig.Wizard.State.put(:wifi_configured, true)

        current_method = Clawrig.Wizard.State.get(:network_method)
        method = if current_method == :ethernet, do: :both, else: :wifi
        Clawrig.Wizard.State.put(:network_method, method)

        {:noreply, %{state | mode: :station, connecting: false, connected_ssid: ssid}}

      {:error, reason} ->
        Logger.warning("WiFi connect to #{ssid} failed: #{inspect(reason)}, restarting hotspot")
        Commands.impl().start_hotspot()
        {:noreply, %{state | mode: :ap, connecting: false}}
    end
  end
end
