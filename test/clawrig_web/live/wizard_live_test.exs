defmodule ClawrigWeb.WizardLiveTest do
  use ClawrigWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Clawrig.Integrations.Config
  alias Clawrig.TestSupport.MockTelegramHTTP
  alias Clawrig.Wizard.State

  setup do
    original_home = System.get_env("HOME")

    home =
      Path.join(System.tmp_dir!(), "clawrig-wizard-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    System.put_env("HOME", home)

    original_http = Application.get_env(:clawrig, :telegram_http)
    Application.put_env(:clawrig, :telegram_http, MockTelegramHTTP)
    MockTelegramHTTP.reset()

    State.reset()
    Application.put_env(:clawrig, :oobe_complete, false)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_http,
        do: Application.put_env(:clawrig, :telegram_http, original_http),
        else: Application.delete_env(:clawrig, :telegram_http)

      Application.delete_env(:clawrig, :oobe_complete)
      File.rm_rf(home)
    end)

    :ok
  end

  test "renders wizard on /setup starting at preflight", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/setup")
    assert html =~ "ClawRig"
    assert html =~ "Connectivity"
  end

  test "defaults to new mode", %{conn: conn} do
    {:ok, _view, _html} = live(conn, "/setup")
    assert State.get(:mode) == :new
  end

  test "can navigate forward after preflight", %{conn: conn} do
    State.merge(%{step: :preflight, preflight_done: true})

    {:ok, view, _html} = live(conn, "/setup")
    html = view |> element("button[phx-click=nav_next]") |> render_click()
    assert html =~ "OpenClaw"
  end

  test "install step shows OpenClaw", %{conn: conn} do
    State.merge(%{step: :install, preflight_done: true})

    {:ok, _view, html} = live(conn, "/setup")
    assert html =~ "OpenClaw"
  end

  test "receipt step shows completion", %{conn: conn} do
    State.merge(%{
      step: :receipt,
      preflight_done: true,
      install_done: true,
      launch_done: true,
      verify_passed: true
    })

    {:ok, _view, html} = live(conn, "/setup")
    assert html =~ "all set"
  end

  test "telegram setup creates a nonce deep link and links the owner chat", %{conn: conn} do
    token = "123:abc"

    MockTelegramHTTP.put_get_me(
      token,
      {:ok,
       %{
         status: 200,
         body: %{
           "ok" => true,
           "result" => %{"first_name" => "Pi Bot", "username" => "pi_bot"}
         }
       }}
    )

    State.merge(%{step: :telegram, preflight_done: true, provider_done: true})

    {:ok, view, _html} = live(conn, "/setup")

    view |> element("button[phx-click=tg_start]") |> render_click()

    view
    |> element("form[phx-submit=tg_validate]")
    |> render_submit(%{"token" => token})

    html = render(view)
    nonce = State.get(:tg_nonce)

    assert html =~ "Send <strong>/start</strong>, then tap <strong>Check now</strong>."
    assert nonce =~ "clawrig_"
    assert html =~ nonce

    MockTelegramHTTP.put_updates(
      token,
      {:ok,
       %{
         status: 200,
         body: %{
           "ok" => true,
           "result" => [
             %{
               "update_id" => 33,
               "message" => %{
                 "chat" => %{"type" => "private", "id" => 456, "first_name" => "Bradley"},
                 "text" => "/start #{nonce}"
               }
             }
           ]
         }
       }}
    )

    view |> element("button[phx-click=tg_check_now]") |> render_click()
    html = render(view)

    assert html =~ "Connected"
    assert State.get(:tg_chat_id) == "456"

    assert {:connected, %{bot_token: ^token, allow_from: ["456"], dm_policy: "allowlist"}} =
             Config.telegram_status()

    assert [
             {^token, "sendMessage",
              %{
                "chat_id" => "456",
                "text" => text
              }}
           ] = MockTelegramHTTP.sent_messages()

    assert text =~ "This chat is now linked to your Pi"
  end
end
