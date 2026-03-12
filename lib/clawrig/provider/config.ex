defmodule Clawrig.Provider.Config do
  @moduledoc """
  Writes openclaw.json provider configuration for OpenAI-compatible endpoints.
  Supports LiteLLM proxies, Fireworks, Groq, Together AI, and any provider
  that exposes an OpenAI-compatible /v1 API.
  """

  @doc """
  Write an OpenAI-compatible provider to ~/.openclaw/openclaw.json.

  Sets up:
  - `models.providers.<slug>` with baseUrl, apiKey, api type, and model list
  - `agents.defaults.model.primary` to `<slug>/<model_id>`

  TODO: Migrate to OpenClaw SecretRefs workflow instead of plaintext apiKey.
  """
  @spec write_compatible(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def write_compatible(base_url, api_key, model_id, display_name \\ "custom") do
    home = System.get_env("HOME") || "/root"
    config_path = Path.join(home, ".openclaw/openclaw.json")
    provider_slug = slug(display_name)

    config =
      case File.read(config_path) do
        {:ok, contents} ->
          case String.trim(contents) do
            "" -> %{}
            json -> Jason.decode!(json)
          end

        _ ->
          %{}
      end

    # Provider config matching OpenClaw's models.providers format
    provider_config = %{
      "baseUrl" => base_url,
      "apiKey" => api_key,
      "api" => "openai-completions",
      "models" => [
        %{
          "id" => model_id,
          "name" => "#{display_name} (#{model_id})"
        }
      ]
    }

    config =
      config
      |> deep_put(["models", "mode"], "merge")
      |> deep_put(["models", "providers", provider_slug], provider_config)
      |> deep_put(["agents", "defaults", "model", "primary"], "#{provider_slug}/#{model_id}")

    File.mkdir_p!(Path.dirname(config_path))

    case write_atomic(config_path, Jason.encode!(config, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to write openclaw.json: #{inspect(reason)}"}
    end
  rescue
    Jason.DecodeError -> {:error, "Provider config error: openclaw.json is invalid JSON"}
    e -> {:error, "Provider config error: #{Exception.message(e)}"}
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(fn s -> if s == "", do: "custom", else: s end)
  end

  # Deep-put a value into a nested map, creating intermediate maps as needed.
  defp deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  defp deep_put(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, deep_put(child, rest, value))
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
