defmodule ClawrigWeb.AuthController do
  use ClawrigWeb, :controller

  alias Clawrig.DashboardAuth

  def new(conn, _params) do
    if get_session(conn, :dashboard_auth) do
      redirect(conn, to: "/")
    else
      error = get_session(conn, :auth_error)
      conn = delete_session(conn, :auth_error)
      render(conn, :new, error: error)
    end
  end

  def create(conn, %{"password" => password}) do
    if DashboardAuth.verify_password(password) do
      conn
      |> put_session(:dashboard_auth, true)
      |> configure_session(renew: true)
      |> redirect(to: "/")
    else
      conn
      |> put_session(:auth_error, "Invalid password")
      |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end
end
