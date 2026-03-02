defmodule ClawrigWeb.OAuthCallbackController do
  use ClawrigWeb, :controller

  alias Clawrig.Wizard.{OAuth, State}

  def callback(conn, %{"code" => code, "state" => state_param}) do
    # Retrieve the stored PKCE verifier and expected state
    wizard_state = State.get()
    oauth_flow = wizard_state[:oauth_flow]

    cond do
      is_nil(oauth_flow) ->
        send_resp(conn, 400, "No OAuth flow in progress")

      oauth_flow.state != state_param ->
        send_resp(conn, 400, "State mismatch")

      true ->
        case OAuth.exchange_code(code, oauth_flow.verifier) do
          {:ok, tokens} ->
            State.merge(%{oauth_tokens: tokens, oauth_flow: nil})
            Phoenix.PubSub.broadcast(Clawrig.PubSub, "oauth", {:oauth_complete, tokens})

            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, success_html())

          {:error, _reason} ->
            send_resp(conn, 400, "Token exchange failed")
        end
    end
  end

  def callback(conn, _params) do
    send_resp(conn, 400, "Missing code or state parameter")
  end

  defp success_html do
    """
    <!doctype html><html><head><meta charset="utf-8"/>
    <title>Success</title>
    <style>*{margin:0;box-sizing:border-box}body{min-height:100vh;display:grid;place-items:center;background:#f7f7f8;font-family:-apple-system,sans-serif;color:#1a1a1a}.card{text-align:center;padding:48px}.icon{font-size:48px;margin-bottom:16px}h1{font-size:1.2rem;margin-bottom:8px}p{color:#6e6e80;font-size:0.92rem}</style>
    </head><body><div class="card"><div class="icon">&#10003;</div><h1>Connected</h1><p>You can close this window and return to ClawRig.</p></div>
    <script>setTimeout(()=>window.close(),1500)</script>
    </body></html>
    """
  end
end
