defmodule Clawrig.Gateway.SessionStore do
  @moduledoc """
  Helpers for invalidating OpenClaw's persisted conversation sessions.

  OpenClaw snapshots skills/tools into session metadata, so config changes that
  affect available skills need a fresh session on the next turn.
  """

  @spec invalidate_all(String.t() | nil) :: :ok | {:error, String.t()}
  def invalidate_all(home \\ default_home()) do
    home
    |> session_directories()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case invalidate_directory(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp invalidate_directory(dir) do
    :ok = File.mkdir_p(dir)
    store_path = Path.join(dir, "sessions.json")

    stale_files =
      case read_session_file_paths(store_path, dir) do
        {:ok, files} -> files
        {:error, _reason} -> []
      end

    with :ok <- File.write(store_path, "{}\n"),
         :ok <- delete_files(stale_files) do
      :ok
    else
      {:error, reason} ->
        {:error, "Could not invalidate OpenClaw sessions in #{dir}: #{reason}"}
    end
  end

  defp read_session_file_paths(store_path, dir) do
    if File.exists?(store_path) do
      with {:ok, content} <- File.read(store_path),
           {:ok, sessions} <- Jason.decode(content) do
        files =
          sessions
          |> Map.values()
          |> Enum.map(&Map.get(&1, "sessionFile"))
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&Path.expand/1)
          |> Enum.filter(&String.starts_with?(&1, Path.expand(dir)))

        {:ok, files}
      else
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:ok, []}
    end
  end

  defp delete_files(files) do
    Enum.reduce_while(files, :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp session_directories(home) do
    agents_root = Path.join([home || default_home(), ".openclaw", "agents"])
    dirs = Path.wildcard(Path.join([agents_root, "*", "sessions"]))

    if dirs == [] do
      [Path.join([agents_root, "main", "sessions"])]
    else
      dirs
    end
  end

  defp default_home do
    System.get_env("HOME") || System.user_home() || "/home/pi"
  end
end
