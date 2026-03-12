defmodule ClawrigWeb.ChatLiveTest do
  use ClawrigWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clawrig.Gateway.MockOperatorClient

  setup do
    Application.put_env(:clawrig, :oobe_complete, true)
    MockOperatorClient.reset()

    on_exit(fn ->
      Application.delete_env(:clawrig, :oobe_complete)
      MockOperatorClient.reset()
    end)

    :ok
  end

  test "renders chat history when connected", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)

    :ok =
      MockOperatorClient.seed_history([
        %{
          id: "history-1",
          kind: :message,
          role: "assistant",
          content: "Gateway history",
          streaming: false,
          status: "done"
        }
      ])

    {:ok, view, html} = live(conn, ~p"/chat")
    Process.sleep(20)

    assert html =~ "Chat"
    assert render(view) =~ "Gateway history"
  end

  test "filters blank non-streaming history messages", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)

    :ok =
      MockOperatorClient.seed_history([
        %{
          id: "history-empty",
          kind: :message,
          role: "assistant",
          content: "",
          streaming: false,
          status: "done"
        },
        %{
          id: "history-2",
          kind: :message,
          role: "assistant",
          content: "Visible history",
          streaming: false,
          status: "done"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/chat")
    Process.sleep(20)

    html = render(view)
    assert html =~ "Visible history"
    refute html =~ ~s(id="chat-item-history-empty")
  end

  test "filters tool result history messages", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)

    :ok =
      MockOperatorClient.seed_history([
        %{
          id: "history-tool",
          kind: :message,
          role: "toolResult",
          content: "(no output)",
          streaming: false,
          status: "done"
        },
        %{
          id: "history-3",
          kind: :message,
          role: "assistant",
          content: "Visible assistant reply",
          streaming: false,
          status: "done"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/chat")
    Process.sleep(20)

    html = render(view)
    assert html =~ "Visible assistant reply"
    refute html =~ "(no output)"
    refute html =~ ~s(id="chat-item-history-tool")
  end

  test "ignores blank assistant completion events", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)
    {:ok, view, _html} = live(conn, ~p"/chat")

    MockOperatorClient.emit(
      {:chat_done, "agent:main:main", "run-blank",
       %{
         id: "blank-live",
         kind: :message,
         role: "assistant",
         content: "",
         streaming: false,
         status: "done",
         run_id: "run-blank"
       }}
    )

    Process.sleep(20)

    refute render(view) =~ ~s(id="chat-item-blank-live")
  end

  test "ignores echoed user completion events", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)
    {:ok, view, _html} = live(conn, ~p"/chat")

    MockOperatorClient.emit(
      {:chat_done, "agent:main:main", nil,
       %{
         id: "user-echo",
         kind: :message,
         role: "user",
         content: "Echoed user event",
         streaming: false,
         status: "done"
       }}
    )

    Process.sleep(20)

    refute render(view) =~ "Echoed user event"
  end

  test "streams a response after submit", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)
    {:ok, view, _html} = live(conn, ~p"/chat")

    _html = render_submit(view, "chat_submit", %{"text" => "hello"})

    Process.sleep(160)
    html = render(view)

    assert html =~ "hello"
    assert html =~ "Mock response to: hello"
  end

  test "shows pairing state and can pair locally", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat")

    assert html =~ "Gateway pairing required"

    view |> element("button", "Connect Chat to Gateway") |> render_click()
    Process.sleep(20)

    assert render(view) =~ "Connected"
  end

  test "pairing failure clears connecting state and shows the error", %{conn: conn} do
    :ok = MockOperatorClient.set_pair_result({:error, "pairing timed out"})
    {:ok, view, _html} = live(conn, ~p"/chat")

    view |> element("button", "Connect Chat to Gateway") |> render_click()
    Process.sleep(40)

    html = render(view)
    assert html =~ "pairing timed out"
    assert html =~ "Connect Chat to Gateway"
    refute html =~ "Connecting..."
  end

  test "renders approval card and resolves it", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)
    {:ok, view, _html} = live(conn, ~p"/chat")

    MockOperatorClient.emit(
      {:chat_approval_requested,
       %{
         id: "approval-1",
         kind: :approval,
         title: "Restart Gateway",
         detail: "The agent wants to restart the Gateway.",
         status: "pending"
       }}
    )

    Process.sleep(20)
    assert render(view) =~ "Restart Gateway"

    view
    |> element(~s|button[phx-value-approval_id="approval-1"][phx-value-decision="approve"]|)
    |> render_click()

    Process.sleep(20)

    assert render(view) =~ "approved"
  end

  test "stop leaves partial response visible", %{conn: conn} do
    :ok = MockOperatorClient.set_status(:connected)
    {:ok, view, _html} = live(conn, ~p"/chat")

    _html = render_submit(view, "chat_submit", %{"text" => "stop me"})
    Process.sleep(40)

    view |> element(~s|button[aria-label="Stop generation"]|) |> render_click()
    Process.sleep(20)

    html = render(view)
    assert html =~ "Mock response to: stop me"
    refute html =~ ~s(aria-label="Stop generation")
  end
end
