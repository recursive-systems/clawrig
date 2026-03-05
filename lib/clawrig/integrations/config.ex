defmodule Clawrig.Integrations.Config do
  @moduledoc """
  Reads and writes integration config in ~/.openclaw/openclaw.json.
  """

  @doc """
  Returns true if a Brave Search API key is configured in openclaw.json.
  """
  def brave_configured? do
    case read_config() do
      %{"tools" => %{"web" => %{"search" => %{"apiKey" => key}}}}
      when is_binary(key) and key != "" ->
        true

      _ ->
        false
    end
  end

  @doc """
  Write Brave Search API key to openclaw.json under tools.web.search.
  """
  @spec write_brave_key(String.t()) :: :ok | {:error, String.t()}
  def write_brave_key(api_key) do
    config =
      read_config()
      |> deep_put(["tools", "web", "search", "provider"], "brave")
      |> deep_put(["tools", "web", "search", "apiKey"], api_key)

    write_config(config)
  rescue
    e -> {:error, "Failed to write Brave config: #{Exception.message(e)}"}
  end

  @doc """
  Remove Brave Search config from openclaw.json.
  """
  @spec remove_brave_key() :: :ok | {:error, String.t()}
  def remove_brave_key do
    config = read_config()

    config =
      case config do
        %{"tools" => %{"web" => web}} when is_map(web) ->
          web = Map.delete(web, "search")

          if web == %{} do
            tools = Map.delete(config["tools"], "web")

            if tools == %{},
              do: Map.delete(config, "tools"),
              else: Map.put(config, "tools", tools)
          else
            put_in(config, ["tools", "web"], web)
          end

        _ ->
          config
      end

    write_config(config)
  rescue
    e -> {:error, "Failed to remove Brave config: #{Exception.message(e)}"}
  end

  # -- Private --

  defp config_path do
    home = System.get_env("HOME") || "/root"
    Path.join(home, ".openclaw/openclaw.json")
  end

  defp read_config do
    case File.read(config_path()) do
      {:ok, contents} -> Jason.decode!(contents)
      _ -> %{}
    end
  end

  defp write_config(config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, Jason.encode!(config, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to write openclaw.json: #{inspect(reason)}"}
    end
  end

  defp deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  defp deep_put(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, deep_put(child, rest, value))
  end
end
