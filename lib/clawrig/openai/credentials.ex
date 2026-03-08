defmodule Clawrig.OpenAI.Credentials do
  @moduledoc """
  Writes OAuth credentials from the device code flow to OpenClaw's auth store.
  Used by both the wizard (OOBE) and dashboard (re-auth) flows.
  """

  alias Clawrig.System.Commands

  defp auth_profiles_path do
    Application.get_env(
      :clawrig,
      :auth_profiles_path,
      Path.expand("~/.openclaw/agents/main/agent/auth-profiles.json")
    )
  end

  @doc """
  Persists OAuth credentials to auth-profiles.json and configures the
  OpenClaw agent to use them. Returns `:ok` or `{:error, reason}`.
  """
  @spec write(map()) :: :ok | {:error, String.t()}
  def write(oauth_creds) do
    profile_id =
      if is_binary(oauth_creds.email) and oauth_creds.email != "",
        do: "openai-codex:#{oauth_creds.email}",
        else: "openai-codex:default"

    credential = %{
      "type" => "oauth",
      "provider" => "openai-codex",
      "access" => oauth_creds.access,
      "refresh" => oauth_creds.refresh,
      "expires" => oauth_creds.expires,
      "email" => oauth_creds.email
    }

    store =
      case File.read(auth_profiles_path()) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{"version" => 1, "profiles" => %{}}
      end

    store = put_in(store, ["profiles", profile_id], credential)

    case File.write(auth_profiles_path(), Jason.encode!(store, pretty: true)) do
      :ok ->
        Commands.impl().run_openclaw([
          "config",
          "set",
          "auth.profiles.#{profile_id}",
          Jason.encode!(%{provider: "openai-codex", mode: "oauth"}),
          "--strict-json"
        ])

        Commands.impl().run_openclaw([
          "config",
          "set",
          "agents.defaults.model.primary",
          "openai-codex/gpt-5.3-codex"
        ])

        :ok

      {:error, reason} ->
        {:error, "Failed to write auth-profiles.json: #{inspect(reason)}"}
    end
  end

  @doc "Returns true when at least one OpenAI Codex OAuth profile is present."
  def auth_configured? do
    case File.read(auth_profiles_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"profiles" => profiles}} when is_map(profiles) ->
            Enum.any?(profiles, fn {_id, profile} ->
              is_map(profile) and profile["provider"] == "openai-codex" and
                is_binary(profile["refresh"]) and profile["refresh"] != ""
            end)

          _ ->
            false
        end

      _ ->
        false
    end
  end
end
