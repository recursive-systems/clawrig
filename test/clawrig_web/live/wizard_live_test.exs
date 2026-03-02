defmodule ClawrigWeb.WizardLiveTest do
  use ClawrigWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Clawrig.Wizard.State

  setup do
    State.reset()
    Application.put_env(:clawrig, :oobe_complete, false)
    on_exit(fn -> Application.delete_env(:clawrig, :oobe_complete) end)
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
end
