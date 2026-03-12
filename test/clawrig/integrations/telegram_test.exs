defmodule Clawrig.Integrations.TelegramTest do
  use ExUnit.Case, async: false

  alias Clawrig.Integrations.Telegram
  alias Clawrig.TestSupport.MockTelegramHTTP

  setup do
    original_http = Application.get_env(:clawrig, :telegram_http)
    Application.put_env(:clawrig, :telegram_http, MockTelegramHTTP)
    MockTelegramHTTP.reset()

    on_exit(fn ->
      if original_http,
        do: Application.put_env(:clawrig, :telegram_http, original_http),
        else: Application.delete_env(:clawrig, :telegram_http)
    end)

    :ok
  end

  test "validate_token returns bot metadata" do
    MockTelegramHTTP.put_get_me(
      "123:abc",
      {:ok,
       %{
         status: 200,
         body: %{"ok" => true, "result" => %{"first_name" => "Pi Bot", "username" => "pi_bot"}}
       }}
    )

    assert {:ok, %{bot_name: "Pi Bot", bot_username: "pi_bot"}} =
             Telegram.validate_token("123:abc")
  end

  test "detect_owner_start matches the expected nonce after baseline" do
    MockTelegramHTTP.put_updates(
      "123:abc",
      {:ok,
       %{
         status: 200,
         body: %{
           "ok" => true,
           "result" => [
             %{
               "update_id" => 10,
               "message" => %{
                 "chat" => %{"type" => "private", "id" => 44},
                 "text" => "/start old_nonce"
               }
             },
             %{
               "update_id" => 11,
               "message" => %{
                 "chat" => %{"type" => "private", "id" => 99, "first_name" => "Bradley"},
                 "text" => "/start clawrig_token"
               }
             }
           ]
         }
       }}
    )

    assert {:ok, %{chat_id: "99", first_name: "Bradley", update_id: 11}} =
             Telegram.detect_owner_start("123:abc", "clawrig_token", 10)
  end

  test "detect_owner_start ignores non-matching updates" do
    MockTelegramHTTP.put_updates(
      "123:abc",
      {:ok,
       %{
         status: 200,
         body: %{
           "ok" => true,
           "result" => [
             %{
               "update_id" => 11,
               "message" => %{
                 "chat" => %{"type" => "group", "id" => 99},
                 "text" => "/start clawrig_token"
               }
             },
             %{
               "update_id" => 12,
               "message" => %{"chat" => %{"type" => "private", "id" => 22}, "text" => "/start"}
             }
           ]
         }
       }}
    )

    assert :no_messages = Telegram.detect_owner_start("123:abc", "clawrig_token", 10)
  end

  test "send_message records outgoing notification" do
    assert :ok = Telegram.send_message("123:abc", "456", "hello")

    assert [{"123:abc", "sendMessage", %{"chat_id" => "456", "text" => "hello"}}] =
             MockTelegramHTTP.sent_messages()
  end
end
