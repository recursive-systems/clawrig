defmodule Clawrig.Integrations.Telegram do
  @moduledoc """
  Shared Telegram API helpers used by both the wizard and dashboard flows.
  """

  @start_prefix "clawrig_"

  def validate_token(token) do
    if !String.contains?(token, ":") do
      {:error, "That doesn't look like a bot token. It should contain a colon (:)."}
    else
      case http().get("https://api.telegram.org/bot#{token}/getMe") do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
          {:ok,
           %{
             bot_name: result["first_name"] || "Bot",
             bot_username: result["username"] || ""
           }}

        {:ok, _} ->
          {:error, "Token was rejected by Telegram. Double-check it and try again."}

        {:error, _} ->
          {:error, "Could not reach Telegram. Check your internet connection."}
      end
    end
  end

  def latest_update_id(token) do
    case http().get("https://api.telegram.org/bot#{token}/getUpdates",
           params: [timeout: 0, limit: 1]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => [update | _]}}} ->
        update["update_id"]

      _ ->
        nil
    end
  end

  def generate_nonce do
    @start_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  def deep_link(bot_username, nonce) when is_binary(bot_username) and bot_username != "" do
    "https://t.me/#{bot_username}?start=#{nonce}"
  end

  def detect_owner_start(token, nonce, since_update_id \\ nil) do
    case http().get("https://api.telegram.org/bot#{token}/getUpdates",
           params: [timeout: 0, limit: 20]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => results}}} when results != [] ->
        results
        |> Enum.reverse()
        |> Enum.find_value(fn update ->
          update_id = update["update_id"]

          if stale_update?(since_update_id, update_id) do
            nil
          else
            match_owner_start(update, nonce)
          end
        end)
        |> case do
          {chat_id, first_name, update_id} ->
            {:ok, %{chat_id: chat_id, first_name: first_name, update_id: update_id}}

          nil ->
            :no_messages
        end

      _ ->
        :no_messages
    end
  end

  def send_message(token, chat_id, text) do
    case http().post("https://api.telegram.org/bot#{token}/sendMessage",
           json: %{
             chat_id: chat_id,
             text: text
           }
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
      {:ok, _} -> {:error, "Telegram rejected the message."}
      {:error, _} -> {:error, "Could not reach Telegram."}
    end
  end

  defp match_owner_start(%{"message" => msg, "update_id" => update_id}, nonce)
       when is_map(msg) and is_binary(nonce) do
    text = String.trim(msg["text"] || "")

    if msg["chat"]["type"] == "private" and text == "/start #{nonce}" do
      chat_id = to_string(msg["chat"]["id"])
      first_name = msg["chat"]["first_name"] || "there"
      {chat_id, first_name, update_id}
    end
  end

  defp match_owner_start(_, _), do: nil

  defp stale_update?(since_update_id, update_id)
       when is_integer(since_update_id) and is_integer(update_id),
       do: update_id <= since_update_id

  defp stale_update?(_, _), do: false

  defp http do
    Application.get_env(:clawrig, :telegram_http, Clawrig.Integrations.Telegram.ReqClient)
  end
end

defmodule Clawrig.Integrations.Telegram.ReqClient do
  def get(url, opts \\ []), do: Req.get(url, opts)
  def post(url, opts \\ []), do: Req.post(url, opts)
end
