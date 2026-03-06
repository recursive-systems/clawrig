defmodule ClawrigWeb.Plugs.ModePlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = assign(conn, :oobe_complete, oobe_complete?())

    # When the hotspot is active, redirect all browser requests to the captive
    # portal. This prevents Apple's CNA from navigating to / and landing on
    # the wizard, which confuses the captive portal flow.
    if hotspot_active?() do
      conn
      |> put_resp_header("location", "/portal")
      |> send_resp(302, "")
      |> halt()
    else
      conn
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

  defp hotspot_active? do
    try do
      %{mode: mode} = Clawrig.Wifi.Manager.status()
      mode == :ap
    rescue
      _ -> false
    end
  end
end
