defmodule ClawrigWeb.Hooks.ModeGuard do
  import Phoenix.LiveView

  def on_mount(:oobe_only, params, _session, socket) do
    if oobe_complete?() and !preview_oobe_bypass?(params) do
      {:halt, redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end

  def on_mount(:dashboard_only, _params, _session, socket) do
    if oobe_complete?() do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/setup")}
    end
  end

  defp preview_oobe_bypass?(params) when is_map(params) do
    System.get_env("CLAWRIG_ENABLE_PREVIEW_STATES", "false") == "true" and
      params["preview_setup"] == "1"
  end

  defp preview_oobe_bypass?(_), do: false

  defp oobe_complete? do
    case Application.get_env(:clawrig, :oobe_complete) do
      nil ->
        File.exists?(
          Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
        )

      val ->
        val
    end
  end
end
