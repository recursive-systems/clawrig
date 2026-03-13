defmodule Clawrig.Integrations.BrowserUseBroker do
  @moduledoc """
  HTTP client for the ClawRig Browser Use broker service.
  """

  @type broker_payload :: map()

  @spec proxy_url() :: String.t()
  def proxy_url do
    Application.get_env(:clawrig, :browser_use_broker_url, "https://rs-browser-use.fly.dev")
  end

  @doc """
  Register this device with the Browser Use broker.
  Returns {:ok, body} or {:error, reason}.
  """
  @spec register_device() :: {:ok, broker_payload()} | {:error, String.t()}
  def register_device do
    hostname = Clawrig.DeviceIdentity.hostname()
    device_id = Clawrig.Node.Client.device_id()

    case http().post("#{proxy_url()}/v1/device/register",
           json: %{
             device_id: device_id,
             hostname: hostname,
             organization: organization_payload()
           },
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
        {:ok, body}

      {:ok, %{body: %{"message" => msg}}} when is_binary(msg) ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "Unexpected response (#{status})"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetch current managed trial usage for a device token.
  """
  @spec get_usage(String.t()) :: {:ok, broker_payload()} | {:error, String.t()}
  def get_usage(token) do
    case http().get("#{proxy_url()}/v1/device/usage",
           headers: auth_headers(token),
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, "Invalid Browser Use device token"}

      {:ok, %{body: %{"message" => msg}}} when is_binary(msg) ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "Unexpected response (#{status})"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Submit a browser task to the managed broker.
  """
  @spec run_task(String.t(), broker_payload()) :: {:ok, broker_payload()} | {:error, String.t()}
  def run_task(token, payload) when is_map(payload) do
    case http().post("#{proxy_url()}/v1/browser/run",
           headers: auth_headers(token),
           json: payload,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 202] and is_map(body) ->
        {:ok, body}

      {:ok, %{body: %{"message" => msg}}} when is_binary(msg) ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "Unexpected response (#{status})"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp organization_payload do
    %{
      slug: Application.get_env(:clawrig, :fleet_org_slug, "default-org"),
      name: Application.get_env(:clawrig, :fleet_org_name, "Default Organization")
    }
  end

  defp http do
    Application.get_env(
      :clawrig,
      :browser_use_broker_http,
      Clawrig.Integrations.BrowserUseBroker.ReqClient
    )
  end
end

defmodule Clawrig.Integrations.BrowserUseBroker.ReqClient do
  def get(url, opts \\ []), do: Req.get(url, opts)
  def post(url, opts \\ []), do: Req.post(url, opts)
end
