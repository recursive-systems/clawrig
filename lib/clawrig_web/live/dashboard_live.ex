defmodule ClawrigWeb.DashboardLive do
  use ClawrigWeb, :live_view

  alias Clawrig.System.Commands
  alias Clawrig.Wizard.{OAuth, State}

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Clawrig.PubSub, "oauth")
      Process.send_after(self(), :refresh_status, @refresh_interval)
    end

    socket =
      socket
      |> assign(:gateway_status, :unknown)
      |> assign(:internet, false)
      |> assign(:wifi_ssid, nil)
      |> assign(:version, read_version())
      |> assign(:oauth_status, :unknown)
      |> assign(:oauth_url, nil)
      |> assign(:logs, nil)
      |> assign(:update_status, nil)

    socket = if connected?(socket), do: refresh_status(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ---------- Events ----------

  @impl true
  def handle_event("start_oauth", _params, socket) do
    {verifier, challenge} = OAuth.generate_pkce()
    state_param = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    url = OAuth.build_auth_url(state_param, challenge)

    State.put(:oauth_flow, %{verifier: verifier, state: state_param})

    {:noreply, assign(socket, oauth_url: url, oauth_status: :waiting)}
  end

  def handle_event("restart_gateway", _params, socket) do
    Task.start(fn ->
      Commands.impl().run_openclaw(["gateway", "install"])

      try do
        System.cmd("systemctl", ["restart", "openclaw-gateway"])
      rescue
        _ -> :ok
      end
    end)

    {:noreply, put_flash(socket, :info, "Restarting gateway...")}
  end

  def handle_event("run_repair", _params, socket) do
    Task.start(fn ->
      Commands.impl().run_openclaw(["doctor", "--fix"])
    end)

    {:noreply, put_flash(socket, :info, "Running repair...")}
  end

  def handle_event("reboot", _params, socket) do
    Task.start(fn ->
      Process.sleep(2000)

      try do
        System.cmd("reboot", [])
      rescue
        _ -> :ok
      end
    end)

    {:noreply, put_flash(socket, :info, "Rebooting in 2 seconds...")}
  end

  def handle_event("check_update", _params, socket) do
    send(self(), :check_update)
    {:noreply, assign(socket, :update_status, :checking)}
  end

  def handle_event("view_logs", _params, socket) do
    {:noreply, assign(socket, :logs, read_logs())}
  end

  # ---------- Info ----------

  @impl true
  def handle_info(:refresh_status, socket) do
    Process.send_after(self(), :refresh_status, @refresh_interval)
    {:noreply, refresh_status(socket)}
  end

  def handle_info(:check_update, socket) do
    status =
      try do
        Clawrig.Updater.check()
      rescue
        _ -> {:error, "Updater not available"}
      catch
        :exit, _ -> {:error, "Updater not available"}
      end

    {:noreply, assign(socket, :update_status, status)}
  end

  def handle_info({:oauth_complete, _tokens}, socket) do
    {:noreply, assign(socket, :oauth_status, :connected)}
  end

  def handle_info({ClawrigWeb.WifiComponent, {:wifi_connected, ssid}}, socket) do
    {:noreply, assign(socket, :wifi_ssid, ssid)}
  end

  # ---------- Private ----------

  defp refresh_status(socket) do
    gateway = Commands.impl().gateway_status()
    internet = Commands.impl().check_internet()

    wifi_ssid =
      try do
        {result, 0} = System.cmd("nmcli", ["-t", "-f", "ACTIVE,SSID", "dev", "wifi"])

        result
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, ":", parts: 2) do
            ["yes", ssid] -> ssid
            _ -> nil
          end
        end)
      rescue
        _ -> nil
      end

    oauth_status =
      try do
        tokens = State.get(:oauth_tokens)
        if OAuth.connected?(tokens), do: :connected, else: :disconnected
      rescue
        _ -> :unknown
      end

    socket
    |> assign(:gateway_status, gateway)
    |> assign(:internet, internet)
    |> assign(:wifi_ssid, wifi_ssid)
    |> assign(:oauth_status, oauth_status)
  end

  defp read_version do
    case File.read("/opt/clawrig/VERSION") do
      {:ok, content} -> String.trim(content)
      _ -> "dev"
    end
  end

  defp read_logs do
    repair_log =
      case File.read("/var/log/clawrig-repair.log") do
        {:ok, content} -> content
        _ -> ""
      end

    gateway_log =
      try do
        {output, 0} =
          System.cmd("journalctl", ["-u", "openclaw-gateway", "-n", "50", "--no-pager"])

        output
      rescue
        _ -> ""
      end

    String.trim("--- Repair Log ---\n#{repair_log}\n\n--- Gateway Log ---\n#{gateway_log}")
  end

  # ---------- View helpers ----------

  def status_color(:running), do: "status-ok"
  def status_color(true), do: "status-ok"
  def status_color(:connected), do: "status-ok"
  def status_color(:stopped), do: "status-error"
  def status_color(false), do: "status-error"
  def status_color(:disconnected), do: "status-warn"
  def status_color(_), do: "status-unknown"

  def status_label(:running), do: "Running"
  def status_label(:stopped), do: "Stopped"
  def status_label(true), do: "Online"
  def status_label(false), do: "Offline"
  def status_label(:connected), do: "Connected"
  def status_label(:disconnected), do: "Not connected"
  def status_label(:waiting), do: "Waiting..."
  def status_label(:checking), do: "Checking..."
  def status_label(:unknown), do: "Unknown"
  def status_label(nil), do: "N/A"
  def status_label(other) when is_binary(other), do: other
  def status_label(_), do: "Unknown"

  def tab_class(live_action, tab) when live_action == tab, do: "tab active"
  def tab_class(_live_action, _tab), do: "tab"
end
