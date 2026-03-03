defmodule ClawrigWeb.Hooks.ModeGuard do
  import Phoenix.LiveView

  def on_mount(:oobe_only, _params, _session, socket) do
    if oobe_complete?() do
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
