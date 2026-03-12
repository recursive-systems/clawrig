defmodule Clawrig.TestSupport.MockTelegramHTTP do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  def put_get_me(token, result) do
    Agent.update(__MODULE__, fn state -> put_in(state, [:get_me, token], result) end)
  end

  def put_updates(token, result) do
    Agent.update(__MODULE__, fn state -> put_in(state, [:updates, token], result) end)
  end

  def sent_messages do
    Agent.get(__MODULE__, &Enum.reverse(&1.sent_messages))
  end

  def get(url, _opts \\ []) do
    {token, action} = parse(url)

    Agent.get(__MODULE__, fn state ->
      case action do
        "getMe" -> Map.get(state.get_me, token, {:error, :missing})
        "getUpdates" -> Map.get(state.updates, token, {:ok, ok_response([])})
        _ -> {:error, :unknown}
      end
    end)
  end

  def post(url, opts \\ []) do
    {token, action} = parse(url)
    payload = normalize_keys(Keyword.get(opts, :json, %{}))

    Agent.update(__MODULE__, fn state ->
      update_in(state.sent_messages, &[{token, action, payload} | &1])
    end)

    {:ok, ok_response(%{"message_id" => 1})}
  end

  defp parse(url) do
    %URI{path: path} = URI.parse(url)
    [bot_segment, action] = String.split(path, "/", trim: true)
    <<"bot", token::binary>> = bot_segment
    {token, action}
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_keys(value)} end)
  end

  defp normalize_keys(list) when is_list(list), do: Enum.map(list, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp ok_response(result) do
    %{status: 200, body: %{"ok" => true, "result" => result}}
  end

  defp initial_state do
    %{get_me: %{}, updates: %{}, sent_messages: []}
  end
end
