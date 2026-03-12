defmodule Clawrig.Wizard.Telegram do
  alias Clawrig.Integrations.Config, as: IntegrationsConfig
  alias Clawrig.Integrations.Telegram, as: TelegramService

  def validate_token(token) do
    TelegramService.validate_token(token)
  end

  def latest_update_id(token) do
    TelegramService.latest_update_id(token)
  end

  def generate_nonce do
    TelegramService.generate_nonce()
  end

  def deep_link(bot_username, nonce) do
    TelegramService.deep_link(bot_username, nonce)
  end

  def detect_chat(token, nonce, since_update_id \\ nil) do
    case TelegramService.detect_owner_start(token, nonce, since_update_id) do
      {:ok, %{chat_id: chat_id, first_name: first_name, update_id: update_id}} ->
        send_welcome(token, chat_id, first_name)
        {:ok, %{chat_id: chat_id, first_name: first_name, update_id: update_id}}

      :no_messages ->
        :no_messages
    end
  end

  def save_config(token, chat_id, _bot_name) do
    IntegrationsConfig.write_telegram(token, chat_id)
  end

  def send_setup_complete(token, chat_id) do
    if token && chat_id do
      Task.start(fn ->
        _ =
          TelegramService.send_message(
            token,
            chat_id,
            "✅ Setup is complete. OpenClaw is now starting up. Send a message here in a few seconds and I'll respond."
          )
      end)
    end

    :ok
  end

  defp send_welcome(token, chat_id, first_name) do
    Task.start(fn ->
      _ =
        TelegramService.send_message(
          token,
          chat_id,
          "Hey #{first_name}! This chat is now linked to your Pi. Keep going through setup. You can chat with OpenClaw here once setup is complete."
        )
    end)
  end
end
