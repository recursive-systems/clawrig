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

  def latest_update_id(token) do
    case Req.get("https://api.telegram.org/bot#{token}/getUpdates",
           params: [timeout: 0, limit: 1]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => [update | _]}}} ->
        update["update_id"]

      _ ->
        nil
    end
  end

  def detect_chat(token, since_update_id \\ nil) do
    case Req.get("https://api.telegram.org/bot#{token}/getUpdates",
           params: [timeout: 0, limit: 20]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => results}}} when results != [] ->
        results
        |> Enum.reverse()
        |> Enum.find_value(fn update ->
          update_id = update["update_id"]

          if is_integer(since_update_id) and is_integer(update_id) and
               update_id <= since_update_id do
            nil
          else
            msg = update["message"]
            text = (msg && msg["text"] && String.trim(msg["text"])) || ""

            if (msg && msg["chat"]["type"] == "private") and text == "/start" do
              chat_id = to_string(msg["chat"]["id"])
              first_name = msg["chat"]["first_name"] || "there"
              {chat_id, first_name, update_id}
            end
          end
        end)
        |> case do
          {chat_id, first_name, update_id} ->
            send_welcome(token, chat_id, first_name)
            {:ok, %{chat_id: chat_id, first_name: first_name, update_id: update_id}}

          nil ->
            :no_messages
        end

      _ ->
        :no_messages
    end
  end

  def save_config(token, chat_id, _bot_name) do
    alias Clawrig.System.Commands

    Commands.impl().run_openclaw([
      "channels",
      "add",
      "--channel",
      "telegram",
      "--token",
      token
    ])

    # `openclaw channels add` does not set allowFrom, so merge the detected
    # chat ID into the config so the gateway accepts messages from this user.
    if chat_id do
      home = System.get_env("HOME") || "/root"
      config_path = Path.join(home, ".openclaw/openclaw.json")

      with {:ok, contents} <- File.read(config_path),
           {:ok, config} <- Jason.decode(contents),
           %{"telegram" => tg} <- Map.get(config, "channels", %{}) do
        tg = Map.put(tg, "allowFrom", [chat_id])
        config = put_in(config, ["channels", "telegram"], tg)
        File.write!(config_path, Jason.encode!(config, pretty: true))
      end
    end

    {:ok, true}
  end

  def send_setup_complete(token, chat_id) do
    if token && chat_id do
      Task.start(fn ->
        Req.post("https://api.telegram.org/bot#{token}/sendMessage",
          json: %{
            chat_id: chat_id,
            text:
              "✅ Setup is complete. OpenClaw is now starting up. Send a message here in a few seconds and I'll respond."
          }
        )
      end)
    end

    :ok
  end

  defp send_welcome(token, chat_id, first_name) do
    Task.start(fn ->
      Req.post("https://api.telegram.org/bot#{token}/sendMessage",
        json: %{
          chat_id: chat_id,
          text:
            "Hey #{first_name}! This chat is now linked to your Pi. Keep going through setup. You can chat with OpenClaw here once setup is complete."
        }
      )
    end)
  end
end
