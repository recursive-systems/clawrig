defmodule ClawrigWeb.E2eController do
  use ClawrigWeb, :controller

  alias Clawrig.Wizard.State

  def reset(conn, params) do
    if enabled?() do
      State.reset()
      delete_file(Application.get_env(:clawrig, :dashboard_auth_path))
      delete_file(Application.get_env(:clawrig, :oobe_marker))

      if params["oobe_complete"] do
        touch_file(Application.get_env(:clawrig, :oobe_marker))
      end

      json(conn, %{
        ok: true,
        oobe_complete: params["oobe_complete"] == true,
        state_path: Application.get_env(:clawrig, :state_path),
        oobe_marker: Application.get_env(:clawrig, :oobe_marker),
        dashboard_auth_path: Application.get_env(:clawrig, :dashboard_auth_path)
      })
    else
      send_resp(conn, :not_found, "Not found")
    end
  end

  defp enabled? do
    System.get_env("CLAWRIG_ENABLE_E2E_ROUTES", "false") == "true"
  end

  defp delete_file(nil), do: :ok

  defp delete_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp touch_file(nil), do: :ok

  defp touch_file(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end
end
