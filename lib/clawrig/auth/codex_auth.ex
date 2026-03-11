defmodule Clawrig.Auth.CodexAuth do
  @moduledoc """
  Writes ~/.codex/auth.json so Codex CLI can authenticate using the same
  OAuth tokens obtained during ClawRig's device code flow.

  Both ClawRig and Codex CLI use the same OAuth client ID
  (app_EMoamEEZ73f0CkXaXp7hrann), so tokens are interchangeable.
  """

  require Logger

  @codex_home_dir ".codex"
  @auth_filename "auth.json"

  @doc """
  Write Codex CLI auth.json from OAuth credentials.

  Expects a map with keys: `:access`, `:refresh`, `:id_token`, `:expires`.
  `:expires` is milliseconds since epoch.

  Returns `:ok` or `{:error, reason}`.
  """
  def write_auth(oauth_creds) do
    path = auth_path()
    dir = Path.dirname(path)

    expires_at =
      oauth_creds.expires
      |> div(1000)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()

    auth = %{
      "auth_mode" => "chatgpt",
      "tokens" => %{
        "id_token" => Map.get(oauth_creds, :id_token, ""),
        "access_token" => oauth_creds.access,
        "refresh_token" => oauth_creds.refresh
      },
      "last_refresh" => expires_at
    }

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, Jason.encode!(auth, pretty: true)),
         :ok <- File.chmod(path, 0o600) do
      Logger.info("[CodexAuth] Wrote #{path}")
      :ok
    else
      {:error, reason} ->
        Logger.warning("[CodexAuth] Failed to write #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Returns true if a Codex auth.json exists."
  def auth_exists? do
    File.exists?(auth_path())
  end

  defp auth_path do
    Application.get_env(
      :clawrig,
      :codex_auth_path,
      Path.join([System.get_env("HOME", "/home/pi"), @codex_home_dir, @auth_filename])
    )
  end
end
