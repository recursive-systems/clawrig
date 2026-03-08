defmodule ClawrigWeb.Hooks.AuthGuard do
  import Phoenix.LiveView
  alias Clawrig.DashboardAuth

  def on_mount(:dashboard_auth, _params, session, socket) do
    cond do
      not DashboardAuth.configured?() ->
        {:cont, socket}

      session["dashboard_auth"] == true ->
        {:cont, socket}

      true ->
        {:halt, redirect(socket, to: "/login")}
    end
  end
end
