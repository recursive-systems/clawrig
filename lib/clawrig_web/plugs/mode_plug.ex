defmodule ClawrigWeb.Plugs.ModePlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :oobe_complete, oobe_complete?())
  end

  defp oobe_complete? do
    case Application.get_env(:clawrig, :oobe_complete) do
      nil -> File.exists?(Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete"))
      val -> val
    end
  end
end
