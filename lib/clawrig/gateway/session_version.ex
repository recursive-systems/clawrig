defmodule Clawrig.Gateway.SessionVersion do
  @moduledoc """
  Invalidates persisted OpenClaw sessions after a new ClawRig release boots.

  OpenClaw snapshots skills/tools into stored sessions, so a ClawRig self-update
  that changes bundled skills needs a one-time session reset plus gateway restart
  to make the new capabilities visible in existing chats.
  """

  require Logger

  alias Clawrig.System.Commands

  @spec reconcile() :: :ok | :noop | {:error, String.t()}
  def reconcile do
    current_version = read_current_version()
    marker_path = marker_path()

    case File.read(marker_path) do
      {:ok, stored_version} ->
        if String.trim(stored_version) == current_version do
          :noop
        else
          refresh_sessions_for_version(current_version, marker_path)
        end

      _ ->
        refresh_sessions_for_version(current_version, marker_path)
    end
  end

  defp refresh_sessions_for_version(version, marker_path) do
    Logger.info("[Gateway.SessionVersion] Detected ClawRig release change to #{version}, refreshing OpenClaw sessions")

    with :ok <- Commands.impl().invalidate_agent_sessions(),
         :ok <- Commands.impl().start_gateway(),
         :ok <- persist_version(marker_path, version) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("[Gateway.SessionVersion] Could not refresh sessions for #{version}: #{inspect(reason)}")
        error
    end
  end

  defp persist_version(path, version) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> File.write(path, version <> "\n")
      {:error, reason} -> {:error, "Could not create version marker directory: #{inspect(reason)}"}
    end
    |> case do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Could not write session version marker: #{inspect(reason)}"}
    end
  end

  defp read_current_version do
    case File.read(version_file()) do
      {:ok, content} -> String.trim(content)
      _ -> "dev"
    end
  end

  defp version_file do
    Application.get_env(:clawrig, :clawrig_version_file, "/opt/clawrig/VERSION")
  end

  defp marker_path do
    Application.get_env(
      :clawrig,
      :gateway_session_version_file,
      Path.join([System.get_env("HOME") || "/home/pi", ".openclaw", "clawrig-session-version"])
    )
  end
end
