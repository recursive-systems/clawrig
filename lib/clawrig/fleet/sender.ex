defmodule Clawrig.Fleet.Sender do
  @moduledoc """
  Periodically sends generic fleet heartbeats via the configured transport.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.seconds(60)
  @max_backoff_ms :timer.minutes(15)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    state = %{failures: 0}
    Process.send_after(self(), :tick, startup_delay_ms())
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = maybe_send(state)
    Process.send_after(self(), :tick, next_interval_ms(state.failures))
    {:noreply, state}
  end

  defp maybe_send(state) do
    cond do
      !enabled?() ->
        state

      require_oobe?() and !oobe_complete?() ->
        state

      true ->
        payload = Clawrig.Fleet.Payload.build()
        transport = transport_module()

        case transport.send_heartbeat(payload) do
          {:ok, directives} when is_list(directives) ->
            Clawrig.Fleet.DirectiveProcessor.process(directives)
            if state.failures > 0, do: Logger.info("[Fleet] heartbeat delivery recovered")
            %{state | failures: 0}

          {:ok, :no_directives} ->
            if state.failures > 0, do: Logger.info("[Fleet] heartbeat delivery recovered")
            %{state | failures: 0}

          {:error, reason} ->
            failures = state.failures + 1
            Logger.warning("[Fleet] heartbeat send failed (#{failures}): #{inspect(reason)}")
            %{state | failures: failures}
        end
    end
  end

  defp enabled? do
    Application.get_env(:clawrig, :fleet_enabled, false)
  end

  defp require_oobe? do
    Application.get_env(:clawrig, :fleet_require_oobe, true)
  end

  defp startup_delay_ms do
    Application.get_env(:clawrig, :fleet_startup_delay_ms, 5_000)
  end

  defp next_interval_ms(0) do
    Application.get_env(:clawrig, :fleet_interval_ms, @default_interval_ms)
  end

  defp next_interval_ms(failures) do
    base = Application.get_env(:clawrig, :fleet_interval_ms, @default_interval_ms)
    min(@max_backoff_ms, base * trunc(:math.pow(2, failures)))
  end

  defp transport_module do
    Application.get_env(:clawrig, :fleet_transport, Clawrig.Fleet.HttpTransport)
  end

  defp oobe_complete? do
    marker = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
    File.exists?(marker)
  end
end
