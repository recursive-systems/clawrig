defmodule Clawrig.Fleet.Config do
  @moduledoc """
  Manages fleet configuration persisted to disk.

  Config directives from the fleet backend are merged into a local JSON file
  at `/var/lib/clawrig/fleet-config.json`. Values persist across reboots and
  are read by the updater and other components.
  """

  require Logger

  @config_path "/var/lib/clawrig/fleet-config.json"
  @allowed_keys ~w(pause_updates update_channel)

  def merge(payload) when is_map(payload) do
    path = config_path()
    current = read(path)
    sanitized = Map.take(payload, @allowed_keys)
    updated = Map.merge(current, sanitized)

    case write(path, updated) do
      :ok ->
        Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:fleet_config", {:config_updated, updated})
        :ok

      {:error, reason} ->
        Logger.error("[Fleet.Config] failed to persist config: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get do
    read(config_path())
  end

  def get(key, default \\ nil) do
    Map.get(get(), key, default)
  end

  defp config_path do
    Application.get_env(:clawrig, :fleet_config_path, @config_path)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            map

          {:ok, _other} ->
            Logger.warning("[Fleet.Config] config file contains non-map JSON, treating as empty")
            %{}

          {:error, reason} ->
            Logger.warning("[Fleet.Config] corrupt config at #{path}: #{inspect(reason)}, treating as empty")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("[Fleet.Config] cannot read config at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp write(path, data) do
    dir = Path.dirname(path)
    tmp = "#{path}.tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, encoded} <- Jason.encode(data, pretty: true),
         :ok <- File.write(tmp, encoded),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
