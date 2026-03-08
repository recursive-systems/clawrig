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
    # Delete any stale connection profile for this SSID first
    System.cmd("nmcli", ["connection", "delete", ssid], stderr_to_stdout: true)

    case System.cmd("nmcli", ["device", "wifi", "connect", ssid, "password", password],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        ip = detect_local_ip()
        {:ok, ip}

      {err, _} ->
        if String.contains?(err, "key-mgmt") do
          # WPA3/mixed networks need explicit SAE key management
          connect_wifi_sae(ssid, password)
        else
          {:error, err}
        end
    end
  end

  defp connect_wifi_sae(ssid, password) do
    # Clean up any partial profile from the failed attempt
    System.cmd("nmcli", ["connection", "delete", ssid], stderr_to_stdout: true)

    case System.cmd(
           "nmcli",
           [
             "connection",
             "add",
             "type",
             "wifi",
             "ifname",
             "wlan0",
             "con-name",
             ssid,
             "ssid",
             ssid,
             "wifi-sec.key-mgmt",
             "sae",
             "wifi-sec.psk",
             password
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        case System.cmd("nmcli", ["connection", "up", ssid], stderr_to_stdout: true) do
          {_, 0} ->
            ip = detect_local_ip()
            {:ok, ip}

          {err, _} ->
            System.cmd("nmcli", ["connection", "delete", ssid], stderr_to_stdout: true)
            {:error, err}
        end

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
    alias Clawrig.DeviceIdentity
    conn = DeviceIdentity.hotspot_conn_name()
    ssid = DeviceIdentity.hotspot_ssid()

    # Remove existing hotspot connection if any
    System.cmd("nmcli", ["connection", "delete", conn], stderr_to_stdout: true)

    case System.cmd("nmcli", [
           "connection",
           "add",
           "type",
           "wifi",
           "ifname",
           "wlan0",
           "con-name",
           conn,
           "autoconnect",
           "no",
           "ssid",
           ssid,
           "mode",
           "ap",
           "ipv4.method",
           "shared",
           "ipv4.addresses",
           "192.168.4.1/24"
         ]) do
      {_, 0} ->
        case System.cmd("nmcli", ["connection", "up", conn]) do
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
    conn = Clawrig.DeviceIdentity.hotspot_conn_name()
    stop_captive_portal()
    System.cmd("nmcli", ["connection", "down", conn], stderr_to_stdout: true)
    System.cmd("nmcli", ["connection", "delete", conn], stderr_to_stdout: true)
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
      # Ensure the user service directory exists and bootstrap a service file
      # if `openclaw gateway install` hasn't created one yet. This works around
      # a bug where `openclaw gateway install` fails with "systemctl is-enabled
      # unavailable" when the service file doesn't exist.
      ensure_gateway_service_file()

      # --force ensures the service file is regenerated with the current
      # gateway.auth.token from openclaw.json (onboard may have changed it).
      System.cmd("openclaw", ["gateway", "install", "--force"],
        stderr_to_stdout: true,
        env: user_env()
      )

      # Patch the generated service file with a startup delay so the gateway
      # doesn't get starved on cold boot when competing with other services.
      patch_gateway_startup_delay()

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

  defp patch_gateway_startup_delay do
    home = System.get_env("HOME") || "/home/pi"
    service_path = Path.join([home, ".config/systemd/user/openclaw-gateway.service"])

    if File.exists?(service_path) do
      content = File.read!(service_path)

      unless String.contains?(content, "ExecStartPre") do
        patched = String.replace(content, "ExecStart=", "ExecStartPre=/bin/sleep 15\nExecStart=")
        File.write!(service_path, patched)
      end
    end
  end

  defp ensure_gateway_service_file do
    home = System.get_env("HOME") || "/home/pi"
    service_dir = Path.join(home, ".config/systemd/user")
    service_path = Path.join(service_dir, "openclaw-gateway.service")

    unless File.exists?(service_path) do
      File.mkdir_p!(service_dir)

      openclaw_bin =
        case System.cmd("which", ["openclaw"], stderr_to_stdout: true) do
          {path, 0} -> String.trim(path)
          _ -> "/usr/bin/openclaw"
        end

      File.write!(service_path, """
      [Unit]
      Description=OpenClaw Gateway
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      ExecStartPre=/bin/sleep 15
      ExecStart=#{openclaw_bin} gateway run
      Restart=on-failure
      RestartSec=5
      Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      Environment=HOME=#{home}

      [Install]
      WantedBy=default.target
      """)

      System.cmd("systemctl", ["--user", "daemon-reload"],
        stderr_to_stdout: true,
        env: user_env()
      )
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
  def cpu_temperature do
    case System.cmd("vcgencmd", ["measure_temp"], stderr_to_stdout: true) do
      {"temp=" <> rest, 0} ->
        rest |> String.trim_trailing("'C\n") |> String.to_float()

      _ ->
        nil
    end
  end

  @impl true
  def cpu_voltage do
    case System.cmd("vcgencmd", ["measure_volts"], stderr_to_stdout: true) do
      {"volt=" <> rest, 0} ->
        rest |> String.trim_trailing("V\n") |> String.to_float()

      _ ->
        nil
    end
  end

  @impl true
  def throttle_status do
    case System.cmd("vcgencmd", ["get_throttled"], stderr_to_stdout: true) do
      {"throttled=" <> rest, 0} ->
        hex = String.trim(rest)
        {value, _} = Integer.parse(hex, 16)

        %{
          "raw" => hex,
          "under_voltage" => Bitwise.band(value, 0x1) != 0,
          "frequency_capped" => Bitwise.band(value, 0x2) != 0,
          "throttled" => Bitwise.band(value, 0x4) != 0,
          "soft_temp_limit" => Bitwise.band(value, 0x8) != 0
        }

      _ ->
        %{"raw" => "unknown"}
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

  @impl true
  def tailscale_status do
    installed =
      match?({_, 0}, System.cmd("which", ["tailscale"], stderr_to_stdout: true))

    if installed do
      case System.cmd("sudo", ["tailscale", "status", "--json"], stderr_to_stdout: true) do
        {json, 0} ->
          case Jason.decode(json) do
            {:ok, data} ->
              self_node = data["Self"] || %{}

              ip =
                case self_node["TailscaleIPs"] do
                  [ipv4 | _] -> ipv4
                  _ -> nil
                end

              %{
                installed: true,
                running: true,
                ip: ip,
                hostname: self_node["HostName"]
              }

            _ ->
              %{installed: true, running: false, ip: nil, hostname: nil}
          end

        _ ->
          %{installed: true, running: false, ip: nil, hostname: nil}
      end
    else
      %{installed: false, running: false, ip: nil, hostname: nil}
    end
  end

  @impl true
  def tailscale_up(auth_key) do
    case System.cmd("sudo", ["tailscale", "up", "--authkey", auth_key, "--ssh"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {err, _} -> {:error, String.trim(err)}
    end
  end

  @impl true
  def tailscale_down do
    case System.cmd("sudo", ["tailscale", "down"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, String.trim(err)}
    end
  end

  @impl true
  def tailscale_install do
    script_path = "/tmp/tailscale-install.sh"

    with {_, 0} <-
           System.cmd("curl", ["-fsSL", "-o", script_path, "https://tailscale.com/install.sh"],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd("sudo", ["bash", script_path], stderr_to_stdout: true) do
      File.rm(script_path)
      :ok
    else
      {err, _} ->
        File.rm(script_path)
        {:error, String.trim(err)}
    end
  end

  @impl true
  def autoheal_status do
    Clawrig.Autoheal.state()
  end

  @impl true
  def autoheal_set_enabled(enabled) do
    result = Clawrig.Autoheal.set_enabled(enabled)

    if result == :ok do
      Clawrig.Autoheal.log_action(%{
        "check" => "manual-toggle",
        "action" => if(enabled, do: "enable", else: "disable"),
        "result" => "ok",
        "detail" => "Auto-healing toggled from dashboard"
      })
    end

    result
  end

  @impl true
  def autoheal_run_now do
    service = "clawrig-gateway-watchdog.service"

    case System.cmd("sudo", ["systemctl", "start", service], stderr_to_stdout: true) do
      {_, 0} ->
        Clawrig.Autoheal.log_action(%{
          "check" => "manual-run",
          "action" => "run-fix-now",
          "result" => "ok",
          "detail" => "Triggered #{service}"
        })

        :ok

      {err, _} ->
        reason = String.trim(err)

        Clawrig.Autoheal.log_action(%{
          "check" => "manual-run",
          "action" => "run-fix-now",
          "result" => "error",
          "detail" => reason
        })

        {:error, reason}
    end
  end

  @impl true
  def autoheal_recent_log(limit) do
    Clawrig.Autoheal.recent_logs(limit)
  end
end
