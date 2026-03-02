defmodule Clawrig.Wizard.OAuth do
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"

  def generate_pkce do
    verifier = :crypto.strong_rand_bytes(32) |> base64url()
    challenge = :crypto.hash(:sha256, verifier) |> base64url()
    {verifier, challenge}
  end

  def build_auth_url(state, challenge) do
    params =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri,
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => "pi"
      })

    "#{@authorize_url}?#{params}"
  end

  def exchange_code(code, verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => @client_id,
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => @redirect_uri
      })

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => access, "refresh_token" => refresh} = resp}} ->
        expires_in = Map.get(resp, "expires_in", 3600)
        expires = System.system_time(:millisecond) + expires_in * 1000
        payload = decode_jwt_payload(access)
        auth = get_in(payload, ["https://api.openai.com/auth"])
        account_id = if auth, do: auth["chatgpt_account_id"]

        {:ok,
         %{
           access: access,
           refresh: refresh,
           expires: expires,
           account_id: account_id
         }}

      _ ->
        {:error, "Token exchange failed"}
    end
  end

  def refresh_token(refresh) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => @client_id
      })

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
        new_refresh = Map.get(resp, "refresh_token", refresh)
        expires_in = Map.get(resp, "expires_in", 3600)
        expires = System.system_time(:millisecond) + expires_in * 1000
        payload = decode_jwt_payload(access)
        auth = get_in(payload, ["https://api.openai.com/auth"])
        account_id = if auth, do: auth["chatgpt_account_id"]

        {:ok,
         %{
           access: access,
           refresh: new_refresh,
           expires: expires,
           account_id: account_id
         }}

      _ ->
        {:error, "Refresh failed"}
    end
  end

  def connected?(nil), do: false

  def connected?(tokens) do
    has_access = is_binary(tokens.access) and tokens.access != ""
    not_expired = System.system_time(:millisecond) < tokens.expires
    has_refresh = is_binary(tokens.refresh) and tokens.refresh != ""
    has_access and (not_expired or has_refresh)
  end

  def ensure_fresh(nil), do: {:error, "No tokens"}

  def ensure_fresh(tokens) do
    # 60 second buffer
    if System.system_time(:millisecond) < tokens.expires - 60_000 do
      {:ok, tokens}
    else
      refresh_token(tokens.refresh)
    end
  end

  def write_oauth_json(tokens) do
    home = System.get_env("HOME") || "/root"
    oauth_dir = Path.join([home, ".openclaw", "oauth"])
    File.mkdir_p!(oauth_dir)

    data = %{
      "openai-codex" => %{
        "access" => tokens.access,
        "refresh" => tokens.refresh,
        "expires" => tokens.expires,
        "accountId" => tokens.account_id
      }
    }

    File.write!(Path.join(oauth_dir, "oauth.json"), Jason.encode!(data, pretty: true))
  end

  defp base64url(bytes) do
    Base.url_encode64(bytes, padding: false)
  end

  defp decode_jwt_payload(token) do
    case String.split(token, ".") do
      [_, payload | _] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, data} -> data
              _ -> %{}
            end

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end
end
