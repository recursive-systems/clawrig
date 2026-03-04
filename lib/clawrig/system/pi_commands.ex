defmodule Clawrig.System.PiCommands do
  @behaviour Clawrig.System.Commands

  @impl true
  def scan_networks do
    case System.cmd(
           "nmcli",
           ["-t", "-f", "SSID,SIGNAL,SECURITY,FREQ", "device", "wifi", "list", "--rescan", "yes"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_network_line/1)
        |> Enum.reject(&(&1.ssid == ""))
        |> Enum.uniq_by(& &1.ssid)
        |> Enum.sort_by(& &1.signal, :desc)

      _ ->
        []
    end
  end

  defp parse_network_line(line) do
    case String.split(line, ":", parts: 4) do
      [ssid, signal, security, freq] ->
        %{
          ssid: ssid,
          signal: String.to_integer(signal),
          security: security,
          freq: freq
        }

      _ ->
        %{ssid: "", signal: 0, security: "", freq: ""}
    end
  end

  @impl true
  def connect_wifi(ssid, password) do
    case System.cmd("nmcli", ["device", "wifi", "connect", ssid, "password", password],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        ip = detect_local_ip()
        {:ok, ip}

      {err, _} ->
        {:error, err}
    end
  end

  @impl true
  def detect_local_ip do
    # Use the default route to find the primary interface, then get its IP
    case System.cmd("ip", ["-4", "-o", "route", "show", "default"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/dev\s+(\S+)/, output) do
          [_, iface] -> ip_for_interface(iface)
          _ -> ip_for_interface("eth0") || ip_for_interface("end0") || ip_for_interface("wlan0")
        end

      _ ->
        ip_for_interface("eth0") || ip_for_interface("end0") || ip_for_interface("wlan0")
    end
  end

  @impl true
  def has_ethernet_ip do
    case System.cmd("ip", ["-4", "-o", "addr", "show"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          not String.contains?(line, "wlan") and
            not String.contains?(line, " lo ") and
            Regex.match?(~r/inet \d+\.\d+\.\d+\.\d+/, line)
        end)

      _ ->
        false
    end
  end

  defp ip_for_interface(iface) do
    case System.cmd("ip", ["-4", "-o", "addr", "show", iface], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/inet (\d+\.\d+\.\d+\.\d+)/, output) do
          [_, ip] -> ip
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def start_hotspot do
    # Remove existing hotspot connection if any
    System.cmd("nmcli", ["connection", "delete", "ClawRig-Hotspot"], stderr_to_stdout: true)

    case System.cmd("nmcli", [
           "connection",
           "add",
           "type",
           "wifi",
           "ifname",
           "wlan0",
           "con-name",
           "ClawRig-Hotspot",
           "autoconnect",
           "no",
           "ssid",
           "ClawRig-Setup",
           "mode",
           "ap",
           "ipv4.method",
           "shared",
           "ipv4.addresses",
           "192.168.4.1/24"
         ]) do
      {_, 0} ->
        case System.cmd("nmcli", ["connection", "up", "ClawRig-Hotspot"]) do
          {_, 0} ->
            start_captive_portal()
            :ok

          {err, _} ->
            {:error, err}
        end

      {err, _} ->
        {:error, err}
    end
  end

  @impl true
  def stop_hotspot do
    stop_captive_portal()
    System.cmd("nmcli", ["connection", "down", "ClawRig-Hotspot"], stderr_to_stdout: true)
    System.cmd("nmcli", ["connection", "delete", "ClawRig-Hotspot"], stderr_to_stdout: true)
    :ok
  end

  defp start_captive_portal do
    # iptables redirect is pre-loaded at boot via /etc/iptables/rules.v4.
    # DNS catch-all is handled by NM's shared dnsmasq via
    # /etc/NetworkManager/dnsmasq-shared.d/captive-portal.conf.
    # Nothing to start here.
    :ok
  end

  defp stop_captive_portal do
    :ok
  end

  @impl true
  def check_internet do
    case System.cmd("curl", ["-sSf", "--max-time", "8", "https://api.github.com"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def run_openclaw(args) do
    System.cmd("openclaw", args, stderr_to_stdout: true, env: user_env())
  end

  @impl true
  def gateway_status do
    case System.cmd("openclaw", ["gateway", "status"], stderr_to_stdout: true, env: user_env()) do
      {output, 0} ->
        if String.contains?(output, "RPC probe: ok"), do: :running, else: :stopped

      _ ->
        :stopped
    end
  end

  @impl true
  def start_gateway do
    is_container =
      File.exists?("/.dockerenv") || System.get_env("container") == "docker"

    has_systemd =
      !is_container &&
        match?({_, 0}, System.cmd("which", ["systemctl"], stderr_to_stdout: true))

    if has_systemd do
      # --force ensures the service file is regenerated with the current
      # gateway.auth.token from openclaw.json (onboard may have changed it).
      System.cmd("openclaw", ["gateway", "install", "--force"],
        stderr_to_stdout: true,
        env: user_env()
      )

      # daemon-reload so systemd picks up the regenerated service file
      # (without this, restart uses the stale in-memory unit with an old token).
      System.cmd("systemctl", ["--user", "daemon-reload"],
        stderr_to_stdout: true,
        env: user_env()
      )

      System.cmd("systemctl", ["--user", "enable", "openclaw-gateway.service"],
        stderr_to_stdout: true,
        env: user_env()
      )

      System.cmd("systemctl", ["--user", "restart", "openclaw-gateway.service"],
        stderr_to_stdout: true,
        env: user_env()
      )

      case System.cmd("whoami", [], stderr_to_stdout: true) do
        {user, 0} ->
          System.cmd("sudo", ["loginctl", "enable-linger", String.trim(user)],
            stderr_to_stdout: true
          )

        _ ->
          :ok
      end

      :ok
    else
      port =
        Port.open(
          {:spawn_executable, "/bin/bash"},
          [
            :binary,
            :exit_status,
            args: [
              "-c",
              "nohup openclaw gateway run --force > /tmp/openclaw/gateway-stdout.log 2>&1 &"
            ]
          ]
        )

      Port.close(port)
      :ok
    end
  end

  defp get_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _ -> "1000"
    end
  end

  defp user_env do
    [{"XDG_RUNTIME_DIR", "/run/user/#{get_uid()}"}]
  end

  @impl true
  def install_gateway do
    case System.cmd("openclaw", ["gateway", "install"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, err}
    end
  end

  @impl true
  def run_codex_exec(prompt, schema_path) do
    home = "/home/pi"
    uid = get_uid()

    System.cmd(
      "codex",
      ["exec", "--skip-git-repo-check", "--output-schema", schema_path, prompt],
      stderr_to_stdout: true,
      env: [{"HOME", home}, {"XDG_RUNTIME_DIR", "/run/user/#{uid}"}]
    )
  end
end
