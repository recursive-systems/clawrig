defmodule Clawrig.TestSupport.MockBrowserUseBrokerHTTP do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  def put_register_result(result) do
    Agent.update(__MODULE__, fn state -> %{state | register_result: result} end)
  end

  def put_usage_result(token, result) do
    Agent.update(__MODULE__, fn state -> put_in(state, [:usage_results, token], result) end)
  end

  def put_run_result(token, result) do
    Agent.update(__MODULE__, fn state -> put_in(state, [:run_results, token], result) end)
  end

  def last_run_payload do
    Agent.get(__MODULE__, & &1.last_run_payload)
  end

  def last_register_payload do
    Agent.get(__MODULE__, & &1.last_register_payload)
  end

  def get(url, opts \\ []) do
    token = bearer_token(opts)

    Agent.get(__MODULE__, fn state ->
      case URI.parse(url).path do
        "/v1/device/usage" -> Map.get(state.usage_results, token, {:error, :missing})
        _ -> {:error, :unknown}
      end
    end)
  end

  def post(url, opts \\ []) do
    path = URI.parse(url).path
    token = bearer_token(opts)
    payload = Keyword.get(opts, :json, %{})

    Agent.get_and_update(__MODULE__, fn state ->
      case path do
        "/v1/device/register" ->
          {state.register_result, %{state | last_register_payload: payload}}

        "/v1/browser/run" ->
          result = Map.get(state.run_results, token, {:error, :missing})
          {result, %{state | last_run_payload: payload}}

        _ ->
          {{:error, :unknown}, state}
      end
    end)
  end

  defp bearer_token(opts) do
    opts
    |> Keyword.get(:headers, [])
    |> Enum.find_value(fn
      {"authorization", "Bearer " <> token} -> token
      {"Authorization", "Bearer " <> token} -> token
      _ -> nil
    end)
  end

  defp initial_state do
    %{
      register_result: {:error, :missing},
      usage_results: %{},
      run_results: %{},
      last_run_payload: nil,
      last_register_payload: nil
    }
  end
end
