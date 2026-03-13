defmodule Clawrig.RateLimiter do
  @moduledoc """
  ETS-backed rate limiter for login attempts.

  Tracks failed attempts by client IP. After 5 failures within a
  60-second window the IP is blocked until the window expires or
  `reset/1` is called (on successful login).
  """
  use GenServer

  @max_attempts 5
  @window_seconds 60
  @cleanup_interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # Direct ETS reads/writes — safe because the table is :public and
  # these operations are atomic in ETS. Fails open if table is unavailable
  # (GenServer restarting) so login still works during transient outages.
  def check(ip) do
    now = System.system_time(:second)
    cutoff = now - @window_seconds

    :ets.select_delete(__MODULE__, [{{ip, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    count = :ets.select_count(__MODULE__, [{{ip, :"$1"}, [{:>=, :"$1", cutoff}], [true]}])

    if count >= @max_attempts, do: :blocked, else: :ok
  rescue
    ArgumentError -> :ok
  end

  def record_failure(ip) do
    :ets.insert(__MODULE__, {ip, System.system_time(:second)})
  rescue
    ArgumentError -> :ok
  end

  def reset(ip) do
    :ets.match_delete(__MODULE__, {ip, :_})
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:duplicate_bag, :public, :named_table])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:second) - @window_seconds
    :ets.select_delete(__MODULE__, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)
end
