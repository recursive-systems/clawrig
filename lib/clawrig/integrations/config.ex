defmodule Clawrig.Integrations.Config do
  @moduledoc """
  Reads and writes integration config in ~/.openclaw/openclaw.json.
  """

  @clawrig_plugin_id "clawrig"
  @clawrig_plugin_dir_name "clawrig"
  @browser_skill_id "clawrig-browser-use"
  @meta_integrations_path ["meta", "clawrig", "integrations"]

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
  Returns whether the user explicitly opted out of managed auto-enable for web search.
  """
  @spec search_auto_opt_out?() :: boolean()
  def search_auto_opt_out? do
    get_in(read_config(), @meta_integrations_path ++ ["webSearchOptOut"]) == true
  end

  @doc """
  Returns the current Browser Use integration mode:
  - :managed_trial — using the ClawRig broker with a device token
  - :byok — user's own Browser Use Cloud API key
  - :not_configured — Browser Use is disabled
  """
  @spec browser_mode() :: :managed_trial | :byok | :not_configured
  def browser_mode do
    browser = browser_config() || %{}
    browser_settings = browser_settings(browser)

    cond do
      browser["enabled"] == true and browser_settings["mode"] == "managed_trial" and
        is_binary(browser_settings["deviceToken"]) and browser_settings["deviceToken"] != "" ->
        :managed_trial

      browser["enabled"] == true and browser_settings["mode"] == "byok" and
        is_binary(browser["apiKey"]) and browser["apiKey"] != "" ->
        :byok

      true ->
        :not_configured
    end
  end

  @doc """
  Returns the managed Browser Use device token from openclaw.json, or nil.
  """
  @spec browser_usage_token() :: String.t() | nil
  def browser_usage_token do
    browser = browser_config() || %{}
    browser_settings = browser_settings(browser)

    if browser_settings["mode"] == "managed_trial" do
      browser_settings["deviceToken"]
    end
  end

  @doc """
  Returns whether the user explicitly opted out of managed auto-enable for Browser Use.
  """
  @spec browser_auto_opt_out?() :: boolean()
  def browser_auto_opt_out? do
    get_in(read_config(), @meta_integrations_path ++ ["browserUseOptOut"]) == true
  end

  @doc """
  Writes managed Browser Use broker config to openclaw.json.
  """
  @spec write_browser_trial(String.t()) :: :ok | {:error, String.t()}
  def write_browser_trial(device_token) do
    config =
      read_config()
      |> deep_put(["skills", "entries", @browser_skill_id, "enabled"], true)
      |> deep_put(["skills", "entries", @browser_skill_id, "config", "mode"], "managed_trial")
      |> deep_put(["skills", "entries", @browser_skill_id, "config", "runtime"], "remote")
      |> deep_put(
        ["skills", "entries", @browser_skill_id, "config", "brokerUrl"],
        Clawrig.Integrations.BrowserUseBroker.proxy_url()
      )
      |> deep_put(
        ["skills", "entries", @browser_skill_id, "config", "deviceToken"],
        device_token
      )
      |> remove_key(["skills", "entries", @browser_skill_id, "apiKey"])
      |> remove_key(["skills", "entries", @browser_skill_id, "mode"])
      |> remove_key(["skills", "entries", @browser_skill_id, "runtime"])
      |> remove_key(["skills", "entries", @browser_skill_id, "brokerUrl"])
      |> remove_key(["skills", "entries", @browser_skill_id, "deviceToken"])
      |> remove_path(@meta_integrations_path ++ ["browserUseOptOut"])

    write_config(config)
  rescue
    e -> {:error, "Failed to write Browser Use trial config: #{Exception.message(e)}"}
  end

  @doc """
  Writes Browser Use Cloud BYOK config to openclaw.json.
  """
  @spec write_browser_api_key(String.t()) :: :ok | {:error, String.t()}
  def write_browser_api_key(api_key) do
    config =
      read_config()
      |> deep_put(["skills", "entries", @browser_skill_id, "enabled"], true)
      |> deep_put(["skills", "entries", @browser_skill_id, "config", "mode"], "byok")
      |> deep_put(["skills", "entries", @browser_skill_id, "config", "runtime"], "remote")
      |> deep_put(["skills", "entries", @browser_skill_id, "apiKey"], api_key)
      |> remove_key(["skills", "entries", @browser_skill_id, "brokerUrl"])
      |> remove_key(["skills", "entries", @browser_skill_id, "deviceToken"])
      |> remove_key(["skills", "entries", @browser_skill_id, "config", "brokerUrl"])
      |> remove_key(["skills", "entries", @browser_skill_id, "config", "deviceToken"])
      |> remove_key(["skills", "entries", @browser_skill_id, "mode"])
      |> remove_key(["skills", "entries", @browser_skill_id, "runtime"])
      |> remove_path(@meta_integrations_path ++ ["browserUseOptOut"])

    write_config(config)
  rescue
    e -> {:error, "Failed to write Browser Use Cloud config: #{Exception.message(e)}"}
  end

  @doc """
  Removes Browser Use skill config from openclaw.json.
  """
  @spec remove_browser_config() :: :ok | {:error, String.t()}
  def remove_browser_config do
    read_config()
    |> remove_path(["skills", "entries", @browser_skill_id])
    |> deep_put(@meta_integrations_path ++ ["browserUseOptOut"], true)
    |> write_config()
  rescue
    e -> {:error, "Failed to remove Browser Use config: #{Exception.message(e)}"}
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
      |> remove_path(@meta_integrations_path ++ ["webSearchOptOut"])

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
      |> remove_path(@meta_integrations_path ++ ["webSearchOptOut"])

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

    config
    |> deep_put(@meta_integrations_path ++ ["webSearchOptOut"], true)
    |> write_config()
  rescue
    e -> {:error, "Failed to remove search config: #{Exception.message(e)}"}
  end

  @doc """
  Returns the current Telegram integration state.
  """
  @spec telegram_status() ::
          :not_configured
          | {:connected,
             %{
               bot_token: String.t(),
               allow_from: [String.t()],
               dm_policy: String.t()
             }}
  def telegram_status do
    case telegram_config() do
      %{
        "enabled" => true,
        "botToken" => token,
        "allowFrom" => allow_from
      } = telegram
      when is_binary(token) and token != "" and is_list(allow_from) and allow_from != [] ->
        {:connected,
         %{
           bot_token: token,
           allow_from: Enum.map(allow_from, &to_string/1),
           dm_policy: to_string(telegram["dmPolicy"] || "allowlist")
         }}

      _ ->
        :not_configured
    end
  end

  @doc """
  Returns the raw Telegram config map from openclaw.json, or nil if absent.
  """
  @spec telegram_config() :: map() | nil
  def telegram_config do
    get_in(read_config(), ["channels", "telegram"])
  end

  @doc """
  Writes Telegram owner-DM config to openclaw.json.
  """
  @spec write_telegram(String.t(), String.t()) :: :ok | {:error, String.t()}
  def write_telegram(token, chat_id) do
    config =
      read_config()
      |> deep_put(["channels", "telegram", "enabled"], true)
      |> deep_put(["channels", "telegram", "botToken"], token)
      |> deep_put(["channels", "telegram", "dmPolicy"], "allowlist")
      |> deep_put(["channels", "telegram", "allowFrom"], [to_string(chat_id)])

    write_config(config)
  rescue
    e -> {:error, "Failed to write Telegram config: #{Exception.message(e)}"}
  end

  @doc """
  Returns the current exec security mode: "full", "allowlist", or "not_configured".
  """
  @spec exec_security_mode() :: String.t()
  def exec_security_mode do
    get_in(read_config(), ["tools", "exec", "security"]) || "not_configured"
  end

  @doc """
  Ensure exec defaults for the ClawRig appliance.
  Sets security to "full" and ask to "off" — safe because ClawRig
  is a dedicated single-purpose device with limited blast radius.
  """
  @spec write_exec_defaults() :: :ok | {:error, String.t()}
  def write_exec_defaults do
    config =
      read_config()
      |> deep_put(["tools", "exec", "security"], "full")
      |> deep_put(["tools", "exec", "ask"], "off")
      |> deep_put(["tools", "exec", "host"], "gateway")

    write_config(config)
  rescue
    e -> {:error, "Failed to write exec defaults: #{Exception.message(e)}"}
  end

  @doc """
  Ensures the bundled ClawRig plugin is enabled in openclaw.json.
  """
  @spec write_plugin_defaults() :: :ok | {:error, String.t()}
  def write_plugin_defaults do
    read_config()
    |> ensure_plugin_defaults()
    |> write_config()
  rescue
    e -> {:error, "Failed to write plugin defaults: #{Exception.message(e)}"}
  end

  @doc """
  Returns the current dashboard-facing skills center model.
  """
  @spec skills_center() :: [map()]
  def skills_center do
    plugin_enabled? = clawrig_plugin_enabled?()
    plugin_present? = clawrig_plugin_present?()

    [
      %{
        id: @clawrig_plugin_id,
        name: "ClawRig",
        description:
          "Answers questions about your dashboard, device status, readonly diagnostics, updates, and local usage state.",
        source: "default",
        state:
          cond do
            plugin_present? and plugin_enabled? -> "enabled"
            plugin_present? -> "disabled"
            true -> "broken"
          end,
        detail:
          cond do
            plugin_present? and plugin_enabled? ->
              "Bundled with every device and ready to answer ClawRig-specific questions."

            plugin_present? ->
              "Plugin files are present, but OpenClaw is not configured to load the default ClawRig skill."

            true ->
              "Expected plugin files are missing from #{clawrig_plugin_dir()}."
          end
      },
      %{
        id: "web-search",
        name: "Web Search",
        description: "Optional web lookups for the assistant.",
        source: "optional",
        state: if(search_mode() == :not_configured, do: "disabled", else: "enabled"),
        detail:
          if(search_mode() == :not_configured,
            do: "Available as an optional integration.",
            else: "Configured through the Web Search integration below."
          )
      },
      %{
        id: @browser_skill_id,
        name: "Browser Use",
        description: "Optional Browser Use Cloud browsing for interactive and JS-heavy websites.",
        source: "optional",
        state:
          cond do
            !plugin_present? -> "broken"
            browser_mode() == :not_configured -> "disabled"
            true -> "enabled"
          end,
        detail:
          cond do
            !plugin_present? ->
              "Bundled Browser Use helper files are unavailable because the ClawRig plugin is missing."

            browser_mode() == :not_configured ->
              "Available as an optional integration for interactive browsing tasks."

            browser_mode() == :managed_trial ->
              "Configured through the Browser Use integration below using the ClawRig trial broker."

            true ->
              "Configured through the Browser Use integration below using your Browser Use Cloud key."
          end
      },
      %{
        id: "pdf-export",
        name: "PDF Export",
        description: "Future export helpers for turning responses into PDFs.",
        source: "optional",
        state: "coming_soon",
        detail: "Not shipped in ClawRig v1."
      }
    ]
  end

  @doc """
  Removes Telegram config from openclaw.json.
  """
  @spec remove_telegram() :: :ok | {:error, String.t()}
  def remove_telegram do
    config = read_config()

    config =
      case config do
        %{"channels" => channels} when is_map(channels) ->
          channels = Map.delete(channels, "telegram")

          if channels == %{},
            do: Map.delete(config, "channels"),
            else: Map.put(config, "channels", channels)

        _ ->
          config
      end

    write_config(config)
  rescue
    e -> {:error, "Failed to remove Telegram config: #{Exception.message(e)}"}
  end

  # -- Private --

  defp config_path do
    home = System.get_env("HOME") || "/root"
    Path.join(home, ".openclaw/openclaw.json")
  end

  defp read_config do
    case File.read(config_path()) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> %{}
          json -> Jason.decode!(json)
        end

      _ ->
        %{}
    end
  rescue
    Jason.DecodeError -> %{}
  end

  defp browser_config do
    get_in(read_config(), ["skills", "entries", @browser_skill_id])
  end

  defp browser_settings(%{"config" => settings}) when is_map(settings), do: settings
  defp browser_settings(settings) when is_map(settings), do: settings

  defp write_config(config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))

    encoded =
      config
      |> ensure_plugin_defaults()
      |> Jason.encode!(pretty: true)

    case write_atomic(path, encoded) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to write openclaw.json: #{inspect(reason)}"}
    end
  end

  defp clawrig_plugin_present? do
    File.exists?(Path.join(clawrig_plugin_dir(), "openclaw.plugin.json"))
  end

  defp clawrig_plugin_enabled? do
    read_config()
    |> get_in(["plugins", "entries", @clawrig_plugin_id, "enabled"])
    |> Kernel.==(true)
  end

  defp clawrig_plugin_dir do
    Path.join(clawrig_plugin_root(), @clawrig_plugin_dir_name)
  end

  defp clawrig_plugin_root do
    Application.get_env(:clawrig, :openclaw_plugin_install_root, "/opt/clawrig/plugins")
  end

  defp ensure_plugin_defaults(config) do
    existing_paths = get_in(config, ["plugins", "load", "paths"]) || []

    config
    |> deep_put(
      ["plugins", "load", "paths"],
      prepend_unique(clawrig_plugin_root(), existing_paths)
    )
    |> deep_put(["plugins", "entries", @clawrig_plugin_id, "enabled"], true)
  end

  defp prepend_unique(value, list) when is_list(list) do
    [value | Enum.reject(list, &(&1 == value))]
  end

  defp prepend_unique(value, _), do: [value]

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

  defp remove_path(map, [key]) do
    Map.delete(map, key)
  end

  defp remove_path(map, [key | rest]) do
    case Map.get(map, key) do
      child when is_map(child) ->
        updated_child = remove_path(child, rest)

        if updated_child == %{} do
          Map.delete(map, key)
        else
          Map.put(map, key, updated_child)
        end

      _ ->
        map
    end
  end

  defp write_atomic(path, contents) do
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, contents),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp_path)
        error
    end
  end
end
