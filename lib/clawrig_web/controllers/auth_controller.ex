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
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Clawrig.RateLimiter.check(ip) do
      :blocked ->
        conn
        |> put_session(
          :auth_error,
          "Too many login attempts. Please wait a minute and try again."
        )
        |> redirect(to: "/login")

      :ok ->
        if DashboardAuth.verify_password(password) do
          Clawrig.RateLimiter.reset(ip)

          conn
          |> put_session(:dashboard_auth, true)
          |> configure_session(renew: true)
          |> redirect(to: "/")
        else
          Clawrig.RateLimiter.record_failure(ip)

          conn
          |> put_session(:auth_error, "Invalid password")
          |> redirect(to: "/login")
        end
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end
end
