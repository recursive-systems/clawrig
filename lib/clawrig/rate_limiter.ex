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

  def check(ip) do
    now = System.system_time(:second)
    cutoff = now - @window_seconds

    # Clean old entries for this IP
    :ets.select_delete(__MODULE__, [{{ip, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    count = :ets.select_count(__MODULE__, [{{ip, :"$1"}, [{:>=, :"$1", cutoff}], [true]}])

    if count >= @max_attempts, do: :blocked, else: :ok
  end

  def record_failure(ip) do
    :ets.insert(__MODULE__, {ip, System.system_time(:second)})
  end

  def reset(ip) do
    :ets.match_delete(__MODULE__, {ip, :_})
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
