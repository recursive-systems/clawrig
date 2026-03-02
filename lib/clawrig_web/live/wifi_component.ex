defmodule ClawrigWeb.WifiComponent do
  use ClawrigWeb, :live_component

  alias Clawrig.Wifi.Manager, as: WifiManager

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:networks, [])
     |> assign(:wifi_error, nil)
     |> assign(:scanning, false)
     |> assign(:selected, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, wifi_ssid: assigns.wifi_ssid, id: assigns.id)}
  end

  @impl true
  def handle_event("scan_wifi", _params, socket) do
    socket = assign(socket, scanning: true, selected: nil)

    case WifiManager.scan() do
      {:ok, networks} ->
        {:noreply, assign(socket, networks: networks, scanning: false)}

      _ ->
        {:noreply, assign(socket, :scanning, false)}
    end
  end

  def handle_event("select_network", %{"ssid" => ssid}, socket) do
    selected = if socket.assigns.selected == ssid, do: nil, else: ssid
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("connect_wifi", %{"ssid" => ssid, "password" => password}, socket) do
    case WifiManager.connect(ssid, password) do
      :ok ->
        send(self(), {ClawrigWeb.WifiComponent, {:wifi_connected, ssid}})
        {:noreply, assign(socket, wifi_error: nil, selected: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :wifi_error, to_string(reason))}
    end
  end

  defp signal_level(signal) when signal >= 67, do: 3
  defp signal_level(signal) when signal >= 34, do: 2
  defp signal_level(_signal), do: 1

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="wifi-component">
      <%!-- Connection status banner --%>
      <div class={["wifi-status-banner", if(@wifi_ssid, do: "connected", else: "disconnected")]}>
        <div class="wifi-status-icon">
          <svg :if={@wifi_ssid} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M5 12.55a11 11 0 0 1 14.08 0" /><path d="M1.42 9a16 16 0 0 1 21.16 0" /><path d="M8.53 16.11a6 6 0 0 1 6.95 0" /><circle cx="12" cy="20" r="1" fill="currentColor" />
          </svg>
          <svg :if={!@wifi_ssid} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <line x1="1" y1="1" x2="23" y2="23" /><path d="M16.72 11.06A10.94 10.94 0 0 1 19 12.55" /><path d="M5 12.55a10.94 10.94 0 0 1 5.17-2.39" /><path d="M10.71 5.05A16 16 0 0 1 22.56 9" /><path d="M1.42 9a15.91 15.91 0 0 1 4.7-2.88" /><path d="M8.53 16.11a6 6 0 0 1 6.95 0" /><circle cx="12" cy="20" r="1" fill="currentColor" />
          </svg>
        </div>
        <div class="wifi-status-text">
          <span class="wifi-status-label">{if @wifi_ssid, do: "Connected to", else: "Not connected"}</span>
          <span class="wifi-status-ssid">{@wifi_ssid || "No network"}</span>
        </div>
        <div :if={@wifi_ssid} class="wifi-status-badge">
          <span class="wifi-status-dot"></span>
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@wifi_error} class="wifi-error">
        <svg viewBox="0 0 20 20" fill="currentColor" class="wifi-error-icon">
          <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
        </svg>
        {@wifi_error}
      </div>

      <%!-- Scanning indicator --%>
      <div :if={@scanning} class="wifi-scanning">
        <div class="wifi-scanning-bar"></div>
        <span class="wifi-scanning-text">Scanning nearby networks&hellip;</span>
      </div>

      <%!-- Network list --%>
      <div :if={@networks != []} class="wifi-list">
        <div
          :for={network <- @networks}
          class={[
            "wifi-net",
            network.ssid == @wifi_ssid && "wifi-net-active",
            network.ssid == @selected && "wifi-net-selected"
          ]}
        >
          <div
            class="wifi-net-row"
            phx-click="select_network"
            phx-value-ssid={network.ssid}
            phx-target={@myself}
          >
            <div class="wifi-net-identity">
              <div class={["wifi-signal-bars", "level-#{signal_level(network.signal)}"]}>
                <span class="wifi-bar bar-1"></span>
                <span class="wifi-bar bar-2"></span>
                <span class="wifi-bar bar-3"></span>
              </div>
              <span class="wifi-net-ssid">{network.ssid}</span>
              <span :if={network.ssid == @wifi_ssid} class="wifi-net-connected-tag">Connected</span>
            </div>
            <div class="wifi-net-badges">
              <span :if={network.security != ""} class="wifi-net-lock" title={network.security}>
                <svg viewBox="0 0 16 16" fill="currentColor">
                  <path d="M8 1a3.5 3.5 0 00-3.5 3.5V6H3.75A1.75 1.75 0 002 7.75v5.5c0 .966.784 1.75 1.75 1.75h8.5A1.75 1.75 0 0014 13.25v-5.5A1.75 1.75 0 0012.25 6H11.5V4.5A3.5 3.5 0 008 1zm2 5V4.5a2 2 0 10-4 0V6h4z" />
                </svg>
              </span>
              <span class="wifi-net-signal-pct">{network.signal}%</span>
            </div>
          </div>
          <form
            :if={network.ssid == @selected && network.ssid != @wifi_ssid}
            phx-submit="connect_wifi"
            phx-target={@myself}
            class="wifi-net-form"
          >
            <input type="hidden" name="ssid" value={network.ssid} />
            <input
              type="password"
              name="password"
              placeholder="Enter password"
              class="wifi-net-pass"
              autocomplete="off"
              autofocus
            />
            <button type="submit" class="wifi-net-connect">Connect</button>
          </form>
        </div>
      </div>

      <%!-- Empty state --%>
      <div :if={@networks == [] && !@scanning} class="wifi-empty-state">
        <div class="wifi-empty-icon">
          <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10 24.5a18 18 0 0 1 28 0" opacity="0.3" />
            <path d="M6 19.5a24 24 0 0 1 36 0" opacity="0.15" />
            <path d="M15 29a12 12 0 0 1 18 0" opacity="0.5" />
            <path d="M20 33.5a6 6 0 0 1 8 0" />
            <circle cx="24" cy="38" r="1.5" fill="currentColor" stroke="none" />
          </svg>
        </div>
        <p class="wifi-empty-title">No networks found</p>
        <p class="wifi-empty-hint">Click <strong>Scan</strong> to search for nearby Wi-Fi networks.</p>
      </div>
    </div>
    """
  end
end
