defmodule Clawrig.Wizard.DeviceCode do
  @moduledoc false

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @auth_base "https://auth.openai.com"

  @doc """
  Step 1: Request a user code for device authorization.
  Returns {:ok, %{device_auth_id, user_code, interval}} or {:error, reason}.
  HTTP 404 means the user hasn't enabled device code auth in ChatGPT settings.
  """
  def request_user_code do
    case Req.post("#{@auth_base}/api/accounts/deviceauth/usercode",
           json: %{
             client_id: @client_id,
             audience: "https://api.openai.com/v1",
             scope:
               "openid profile email offline_access " <>
                 "api.responses.write api.responses.read " <>
                 "api.completions.write api.model.read"
           }
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           device_auth_id: body["device_auth_id"],
           user_code: body["user_code"],
           interval: parse_interval(body["interval"])
         }}

      {:ok, %{status: 404}} ->
        {:error, :not_enabled}

      {:ok, %{status: status, body: body}} ->
        {:error, extract_error(body, "Unexpected status #{status}")}

      {:error, err} ->
        {:error, "Could not reach OpenAI: #{inspect(err)}"}
    end
  end

  @doc """
  Step 2: Poll for authorization completion.
  Returns :pending, {:ok, %{authorization_code, code_verifier}}, or {:error, reason}.
  """
  def poll_authorization(device_auth_id, user_code) do
    case Req.post("#{@auth_base}/api/accounts/deviceauth/token",
           json: %{
             device_auth_id: device_auth_id,
             user_code: user_code
           }
         ) do
      {:ok, %{status: 200, body: %{"authorization_pending" => true}}} ->
        :pending

      {:ok, %{status: 200, body: body}} when is_map_key(body, "authorization_code") ->
        {:ok,
         %{
           authorization_code: body["authorization_code"],
           code_verifier: body["code_verifier"]
         }}

      {:ok, %{status: 200, body: body}} ->
        if body["authorization_pending"] do
          :pending
        else
          {:error, body["error_description"] || "Authorization failed"}
        end

      # Codex CLI treats 403/404 as "pending" (retry)
      {:ok, %{status: status}} when status in [403, 404] ->
        :pending

      {:ok, %{status: status, body: body}} ->
        {:error, extract_error(body, "Poll failed (#{status})")}

      {:error, err} ->
        {:error, "Could not reach OpenAI: #{inspect(err)}"}
    end
  end

  @doc """
  Step 3: Exchange authorization code for tokens.
  Returns {:ok, %{id_token, access_token, refresh_token}}.
  """
  def exchange_tokens(authorization_code, code_verifier) do
    case Req.post("#{@auth_base}/oauth/token",
           form: [
             client_id: @client_id,
             grant_type: "authorization_code",
             code: authorization_code,
             code_verifier: code_verifier,
             redirect_uri: "#{@auth_base}/deviceauth/callback"
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           id_token: body["id_token"],
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, extract_error(body, "Token exchange failed (#{status})")}

      {:error, err} ->
        {:error, "Could not reach OpenAI: #{inspect(err)}"}
    end
  end

  @doc """
  Complete the flow — exchange tokens and return OAuth credentials.
  Returns {:ok, %{access, refresh, expires, email}} matching OpenClaw's OAuthCredentials format.
  """
  def complete_flow(%{authorization_code: code, code_verifier: verifier}) do
    with {:ok, tokens} <- exchange_tokens(code, verifier) do
      email = extract_email(tokens.id_token)
      expires_ms = System.system_time(:millisecond) + (tokens.expires_in || 3600) * 1000

      {:ok,
       %{
         access: tokens.access_token,
         refresh: tokens.refresh_token,
         expires: expires_ms,
         email: email
       }}
    end
  end

  defp extract_email(id_token) do
    case decode_jwt_claims(id_token) do
      {:ok, %{"email" => email}} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp decode_jwt_claims(jwt) do
    case String.split(jwt, ".") do
      [_, payload, _ | _] ->
        padded =
          case rem(byte_size(payload), 4) do
            2 -> payload <> "=="
            3 -> payload <> "="
            _ -> payload
          end

        padded = String.replace(String.replace(padded, "-", "+"), "_", "/")

        case Base.decode64(padded) do
          {:ok, json} -> Jason.decode(json)
          _ -> {:error, :decode}
        end

      _ ->
        {:error, :invalid_jwt}
    end
  end

  defp extract_error(%{"error_description" => desc} = _body, _default) when is_binary(desc),
    do: desc

  defp extract_error(%{"error" => %{"message" => msg}}, _default) when is_binary(msg), do: msg
  defp extract_error(%{"error" => err}, _default) when is_binary(err), do: err
  defp extract_error(%{"message" => msg}, _default) when is_binary(msg), do: msg
  defp extract_error(_body, default), do: default

  defp parse_interval(val) when is_integer(val), do: val
  defp parse_interval(val) when is_binary(val), do: String.to_integer(val)
  defp parse_interval(_), do: 5
end
