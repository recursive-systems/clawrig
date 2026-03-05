defmodule Clawrig.Integrations.SearchProxy do
  @moduledoc """
  HTTP client for the ClawRig search proxy service.
  """

  def proxy_url do
    Application.get_env(:clawrig, :search_proxy_url, "https://rs-search-proxy.fly.dev")
  end

  @doc """
  Register this device with the search proxy.
  Returns {:ok, %{token, tier, quota}} or {:error, reason}.
  """
  def register_device do
    hostname = Clawrig.DeviceIdentity.hostname()
    secret = registration_secret()

    case Req.post("#{proxy_url()}/v1/device/register",
           json: %{hostname: hostname, secret: secret},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, "Registration denied. Invalid secret."}

      {:ok, %{body: %{"error" => _, "message" => msg}}} ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "Unexpected response (#{status})"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetch current usage for a device token.
  Returns {:ok, %{used, limit, period, resets_at}} or {:error, reason}.
  """
  def get_usage(token) do
    case Req.get("#{proxy_url()}/v1/device/usage",
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, "Invalid token"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  defp registration_secret do
    Application.get_env(:clawrig, :search_proxy_secret, "")
  end
end
