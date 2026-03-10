defmodule Clawrig.Fleet.Payload do
  @moduledoc """
  Builds a generic, backend-agnostic fleet heartbeat payload.
  """

  alias Clawrig.System.Commands

  def build do
    gateway_status = Commands.impl().gateway_status() |> to_string()
    internet_ok = Commands.impl().check_internet()

    %{
      "organization" => %{
        "slug" => Application.get_env(:clawrig, :fleet_org_slug, "default-org"),
        "name" => Application.get_env(:clawrig, :fleet_org_name, "Default Organization")
      },
      "site" => %{
        "code" => Application.get_env(:clawrig, :fleet_site_code, "default-site"),
        "name" => Application.get_env(:clawrig, :fleet_site_name, "Default Site")
      },
      "device" => %{
        "uid" => Clawrig.DeviceIdentity.hostname(),
        "hostname" => Clawrig.DeviceIdentity.hostname(),
        "local_ip" => Commands.impl().detect_local_ip()
      },
      "versions" => %{
        "os" => os_version(),
        "clawrig" => clawrig_version(),
        "openclaw" => openclaw_version()
      },
      "metrics" => %{
        "gateway_status" => gateway_status,
        "internet_ok" => internet_ok,
        "uptime_sec" => uptime_sec(),
        "cpu_temp_c" => Commands.impl().cpu_temperature(),
        "mem_used_pct" => mem_used_pct(),
        "disk_used_pct" => disk_used_pct()
      },
      "health_summary" => infer_health(gateway_status, internet_ok),
      "observed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp clawrig_version do
    case File.read("/opt/clawrig/VERSION") do
      {:ok, version} -> String.trim(version)
      _ -> "0.0.0-dev"
    end
  end

  defp openclaw_version do
    case Commands.impl().run_openclaw(["--version"]) do
      {output, 0} -> output |> String.trim() |> String.split("\n") |> List.first()
      _ -> nil
    end
  end

  defp os_version do
    with {:ok, content} <- File.read("/etc/os-release"),
         [line] <- Regex.scan(~r/^PRETTY_NAME=(.+)$/m, content),
         [_, value] <- line do
      value |> String.trim() |> String.trim("\"")
    else
      _ -> nil
    end
  end

  defp uptime_sec do
    case File.read("/proc/uptime") do
      {:ok, content} ->
        content
        |> String.split(" ", parts: 2)
        |> List.first()
        |> parse_float_to_int()

      _ ->
        nil
    end
  end

  defp mem_used_pct do
    with {:ok, content} <- File.read("/proc/meminfo"),
         total when is_integer(total) <- meminfo_value(content, "MemTotal"),
         available when is_integer(available) <- meminfo_value(content, "MemAvailable"),
         true <- total > 0 do
      used = total - available
      Float.round(used * 100.0 / total, 1)
    else
      _ -> nil
    end
  end

  defp disk_used_pct do
    case System.cmd("df", ["-P", "/"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.at(1)
        |> parse_df_percent()

      _ ->
        nil
    end
  end

  defp parse_df_percent(nil), do: nil

  defp parse_df_percent(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.at(4)
    |> case do
      nil -> nil
      pct -> pct |> String.trim_trailing("%") |> parse_float_or_int()
    end
  end

  defp meminfo_value(content, key) do
    regex = ~r/^#{Regex.escape(key)}:\s+(\d+)\s+kB$/m

    case Regex.run(regex, content) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp parse_float_to_int(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> trunc(num)
      :error -> nil
    end
  end

  defp parse_float_or_int(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> Float.round(num, 1)
      :error -> nil
    end
  end

  defp infer_health("running", true), do: "healthy"
  defp infer_health(_, _), do: "degraded"
end
