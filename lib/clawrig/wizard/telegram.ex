defmodule Clawrig.Wizard.Telegram do
  def validate_token(token) do
    if !String.contains?(token, ":") do
      {:error, "That doesn't look like a bot token. It should contain a colon (:)."}
    else
      case Req.get("https://api.telegram.org/bot#{token}/getMe") do
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

  def detect_chat(token) do
    case Req.get("https://api.telegram.org/bot#{token}/getUpdates",
           params: [timeout: 0, limit: 5]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => results}}} when results != [] ->
        results
        |> Enum.reverse()
        |> Enum.find_value(fn update ->
          msg = update["message"]

          if msg && msg["chat"]["type"] == "private" do
            chat_id = to_string(msg["chat"]["id"])
            first_name = msg["chat"]["first_name"] || "there"
            {chat_id, first_name}
          end
        end)
        |> case do
          {chat_id, first_name} ->
            send_welcome(token, chat_id, first_name)
            {:ok, %{chat_id: chat_id, first_name: first_name}}

          nil ->
            :no_messages
        end

      _ ->
        :no_messages
    end
  end

  def save_config(token, _chat_id, _bot_name) do
    alias Clawrig.System.Commands

    Commands.impl().run_openclaw([
      "channels",
      "add",
      "--channel",
      "telegram",
      "--token",
      token
    ])

    {:ok, true}
  end

  defp send_welcome(token, chat_id, first_name) do
    Task.start(fn ->
      Req.post("https://api.telegram.org/bot#{token}/sendMessage",
        json: %{
          chat_id: chat_id,
          text:
            "Hey #{first_name}! This chat is now linked to your Pi. Once setup is complete, you'll be able to talk to OpenClaw right here."
        }
      )
    end)
  end
end
