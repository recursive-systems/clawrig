defmodule Clawrig.Wizard.MockDeviceCode do
  @moduledoc """
  Dev mock for device code flow. Simulates the OpenAI device auth flow
  with a fake user code and auto-completing authorization after 3 polls.
  Uses Process dictionary for poll count tracking (runs in LiveView process).
  """

  def request_user_code do
    Process.put(:mock_dc_poll_count, 0)

    {:ok,
     %{
       device_auth_id: "mock-device-auth-id",
       user_code: "OI10-lL5S",
       interval: 2
     }}
  end

  def poll_authorization(_device_auth_id, _user_code \\ nil) do
    count = Process.get(:mock_dc_poll_count, 0)
    Process.put(:mock_dc_poll_count, count + 1)

    if count < 30 do
      :pending
    else
      {:ok,
       %{
         authorization_code: "mock-auth-code",
         code_verifier: "mock-code-verifier"
       }}
    end
  end

  def exchange_tokens(_authorization_code, _code_verifier) do
    {:ok,
     %{
       id_token: "mock-id-token",
       access_token: "mock-access-token",
       refresh_token: "mock-refresh-token"
     }}
  end

  def exchange_api_key(_id_token) do
    {:ok, "sk-proj-mock-device-code-key-for-dev"}
  end

  def complete_flow(%{authorization_code: _code, code_verifier: _verifier}) do
    {:ok,
     %{
       access: "mock-access-token",
       refresh: "mock-refresh-token",
       id_token: "mock-id-token",
       expires: System.system_time(:millisecond) + 3_600_000,
       email: "test@example.com"
     }}
  end
end
