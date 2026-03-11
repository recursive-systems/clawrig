defmodule Clawrig.Gateway.MockTransport do
  @moduledoc false

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{responses: [], sent_frames: []} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{responses: [], sent_frames: []} end)
  end

  def push_responses(responses) when is_list(responses) do
    Agent.update(__MODULE__, fn state -> %{state | responses: state.responses ++ responses} end)
  end

  def sent_frames do
    Agent.get(__MODULE__, &Enum.reverse(&1.sent_frames))
  end

  def connect(_host, _port, _path \\ "/") do
    {:ok, %{id: System.unique_integer([:positive])}, nil}
  end

  def set_mode(transport, _mode), do: {:ok, transport}
  def close(_transport), do: :ok

  def recv(transport, _timeout \\ 10_000) do
    case pop_response() do
      {:ok, frames} -> {:ok, transport, frames}
      {:error, reason} -> {:error, transport, reason}
    end
  end

  def decode(transport, data), do: {:ok, transport, data}

  def stream(_transport, _message), do: :unknown

  def send_frame(transport, frame) do
    Agent.update(__MODULE__, fn state -> %{state | sent_frames: [frame | state.sent_frames]} end)
    {:ok, transport}
  end

  defp pop_response do
    Agent.get_and_update(__MODULE__, fn
      %{responses: [next | rest]} = state -> {next, %{state | responses: rest}}
      %{responses: []} = state -> {{:error, :no_mock_response}, state}
    end)
  end
end
