defmodule Clawrig.Autoheal do
  @moduledoc """
  Lightweight state and action log storage for gateway auto-healing.
  """

  alias Clawrig.System.Commands

  @default_state %{
    "enabled" => true,
    "last_run_at" => nil,
    "last_result" => "unknown",
    "last_action" => nil,
    "last_check" => nil,
    "health" => "unknown"
  }

  def state do
    case File.read(state_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> Map.merge(@default_state, decoded)
          _ -> @default_state
        end

      _ ->
        @default_state
    end
  end

  def enabled? do
    state()["enabled"] != false
  end

  def set_enabled(enabled) when is_boolean(enabled) do
    current = state()

    write_state(
      Map.merge(current, %{
        "enabled" => enabled,
        "last_action" => if(enabled, do: "enabled", else: "disabled"),
        "last_run_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "last_result" => "ok"
      })
    )
  end

  def update_status(attrs) when is_map(attrs) do
    write_state(Map.merge(state(), attrs))
  end

  def run_fix_now do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Commands.impl().gateway_status() do
      :running ->
        payload = %{
          "last_run_at" => now,
          "last_result" => "ok",
          "last_action" => "no-op",
          "last_check" => "manual-run",
          "health" => "healthy"
        }

        update_status(payload)
        log_action(%{
          "check" => "manual-run",
          "action" => "no-op",
          "result" => "ok",
          "detail" => "Gateway already running; no action needed"
        })

        {:ok, :noop, state()}

      _ ->
        _ = Commands.impl().start_gateway()
        Process.sleep(1500)

        gateway_after = Commands.impl().gateway_status()

        {result, health, detail} =
          if gateway_after == :running do
            {"ok", "healthy", "Gateway restart successful"}
          else
            {"warn", "degraded", "Gateway restart attempted but still not connected"}
          end

        payload = %{
          "last_run_at" => now,
          "last_result" => result,
          "last_action" => "restart-gateway",
          "last_check" => "manual-run",
          "health" => health
        }

        update_status(payload)
        log_action(%{
          "check" => "manual-run",
          "action" => "restart-gateway",
          "result" => result,
          "detail" => detail
        })

        {:ok, :restart_attempted, state()}
    end
  end

  def log_action(entry) when is_map(entry) do
    payload =
      Map.merge(%{"ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}, entry)

    with :ok <- ensure_parent(log_path()),
         encoded <- Jason.encode!(payload) do
      File.write(log_path(), encoded <> "\n", [:append])
    end
  end

  def recent_logs(limit \\ 20) do
    case File.read(log_path()) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{"ts" => nil, "action" => "unknown", "result" => "unknown", "detail" => line}
          end
        end)

      _ ->
        []
    end
  end

  def state_path do
    Application.get_env(:clawrig, :autoheal_state_path, "/var/lib/clawrig/autoheal-state.json")
  end

  def log_path do
    Application.get_env(:clawrig, :autoheal_log_path, "/var/lib/clawrig/autoheal-log.jsonl")
  end

  defp write_state(payload) do
    with :ok <- ensure_parent(state_path()),
         encoded <- Jason.encode!(payload, pretty: true),
         :ok <- File.write(state_path(), encoded <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  defp ensure_parent(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end
end
