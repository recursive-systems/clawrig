defmodule Clawrig.Gateway.Watchdog do
  @moduledoc """
  Monitors the OpenClaw gateway process. If the gateway service is running
  but not listening on port 18789 (a known cold-boot issue), restarts it.

  Only runs in prod after OOBE is complete.

  - Initial delay: 45s (let the system settle after boot)
  - Check interval: 60s
  - Restarts after 2 consecutive failures (~2 min of not listening)
  """

  use GenServer

  require Logger

  @initial_delay :timer.seconds(45)
  @check_interval :timer.seconds(60)
  @failure_threshold 2
  @gateway_port 18789

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Clawrig.PubSub, "clawrig:oobe")

    active = enabled?()

    if active do
      Process.send_after(self(), :check, @initial_delay)
    end

    {:ok, %{failures: 0, active: active}}
  end

  @impl true
  def handle_info(:oobe_complete, %{active: true} = state), do: {:noreply, state}

  def handle_info(:oobe_complete, state) do
    if not enabled_without_oobe?() do
      {:noreply, state}
    else
      Logger.info("[GatewayWatchdog] OOBE complete — activating watchdog")
      Process.send_after(self(), :check, @initial_delay)
      {:noreply, %{state | active: true}}
    end
  end

  @impl true
  def handle_info(:check, state) do
    state = do_check(state)
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  defp do_check(state) do
    if port_listening?() do
      if state.failures > 0 do
        Logger.info("[GatewayWatchdog] Gateway is healthy (port #{@gateway_port} listening)")
      end

      %{state | failures: 0}
    else
      failures = state.failures + 1

      Logger.warning(
        "[GatewayWatchdog] Port #{@gateway_port} not listening (#{failures}/#{@failure_threshold})"
      )

      if failures >= @failure_threshold do
        case restart_gateway() do
          :ok -> %{state | failures: 0}
          _ -> %{state | failures: failures}
        end
      else
        %{state | failures: failures}
      end
    end
  end

  defp port_listening? do
    case :gen_tcp.connect(~c"127.0.0.1", @gateway_port, [], 2000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp restart_gateway do
    Logger.warning("[GatewayWatchdog] Restarting gateway service")

    env = [{"XDG_RUNTIME_DIR", "/run/user/#{get_uid()}"}]

    case System.cmd("systemctl", ["--user", "restart", "openclaw-gateway.service"],
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} ->
        Process.sleep(3_000)

        if port_listening?() do
          Logger.info("[GatewayWatchdog] Gateway restart confirmed (port #{@gateway_port} listening)")
          :ok
        else
          Logger.warning(
            "[GatewayWatchdog] Gateway restarted but port #{@gateway_port} still not listening"
          )

          :port_not_ready
        end

      {output, code} ->
        Logger.error("[GatewayWatchdog] Gateway restart failed (exit #{code}): #{output}")
        :restart_failed
    end
  end

  defp get_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _ -> "1000"
    end
  end

  defp enabled? do
    Application.get_env(:clawrig, :env) == :prod and oobe_complete?()
  end

  defp enabled_without_oobe? do
    Application.get_env(:clawrig, :env) == :prod
  end

  defp oobe_complete? do
    marker = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
    File.exists?(marker)
  end
end
