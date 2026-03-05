defmodule Clawrig.Integrations.Config do
  @moduledoc """
  Reads and writes integration config in ~/.openclaw/openclaw.json.
  """

  @doc """
  Returns the current web search mode:
  - :managed — using the ClawRig search proxy (Perplexity via proxy)
  - :byok — user's own Brave API key
  - :not_configured — no search configured
  """
  def search_mode do
    config = read_config()
    search = get_in(config, ["tools", "web", "search"]) || %{}

    cond do
      # Managed: perplexity provider with our proxy baseUrl
      search["provider"] == "perplexity" and
        is_binary(get_in(search, ["perplexity", "baseUrl"])) and
          String.contains?(get_in(search, ["perplexity", "baseUrl"]) || "", "rs-search-proxy") ->
        :managed

      # BYOK: brave provider with an API key
      search["provider"] == "brave" and
        is_binary(search["apiKey"]) and search["apiKey"] != "" ->
        :byok

      true ->
        :not_configured
    end
  end

  @doc """
  Returns the managed device token from openclaw.json, or nil.
  """
  def managed_token do
    config = read_config()
    search = get_in(config, ["tools", "web", "search"]) || %{}

    if search["provider"] == "perplexity" do
      get_in(search, ["perplexity", "apiKey"])
    end
  end

  @doc """
  Write managed search config (Perplexity via proxy) to openclaw.json.

  OpenClaw config format:
    tools.web.search.provider = "perplexity"
    tools.web.search.perplexity.baseUrl = <proxy_url>
    tools.web.search.perplexity.apiKey = <device_token>
    tools.web.search.perplexity.model = "sonar"
  """
  @spec write_managed_search(String.t()) :: :ok | {:error, String.t()}
  def write_managed_search(device_token) do
    config =
      read_config()
      |> deep_put(["tools", "web", "search", "provider"], "perplexity")
      |> deep_put(
        ["tools", "web", "search", "perplexity", "baseUrl"],
        Clawrig.Integrations.SearchProxy.proxy_url()
      )
      |> deep_put(["tools", "web", "search", "perplexity", "apiKey"], device_token)
      |> deep_put(["tools", "web", "search", "perplexity", "model"], "sonar")

    # Remove any leftover Brave BYOK config
    config = remove_key(config, ["tools", "web", "search", "apiKey"])

    write_config(config)
  rescue
    e -> {:error, "Failed to write managed search config: #{Exception.message(e)}"}
  end

  @doc """
  Write Brave Search API key to openclaw.json under tools.web.search (BYOK).
  """
  @spec write_brave_key(String.t()) :: :ok | {:error, String.t()}
  def write_brave_key(api_key) do
    config =
      read_config()
      |> deep_put(["tools", "web", "search", "provider"], "brave")
      |> deep_put(["tools", "web", "search", "apiKey"], api_key)

    # Remove any leftover managed/perplexity config
    config = remove_key(config, ["tools", "web", "search", "perplexity"])

    write_config(config)
  rescue
    e -> {:error, "Failed to write Brave config: #{Exception.message(e)}"}
  end

  @doc """
  Remove all web search config from openclaw.json.
  """
  @spec remove_search_config() :: :ok | {:error, String.t()}
  def remove_search_config do
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
    e -> {:error, "Failed to remove search config: #{Exception.message(e)}"}
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

  defp remove_key(map, [key]) do
    Map.delete(map, key)
  end

  defp remove_key(map, [key | rest]) do
    case Map.get(map, key) do
      child when is_map(child) -> Map.put(map, key, remove_key(child, rest))
      _ -> map
    end
  end
end
