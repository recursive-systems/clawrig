defmodule Clawrig.PreviewState do
  @moduledoc """
  Dev-only preview scenario injector.

  Disabled by default. Enable with `CLAWRIG_ENABLE_PREVIEW_STATES=true`.
  """

  @allowed_scenarios [
    "bootstrapping",
    "gateway-down",
    "provider-disconnected",
    "node-connected",
    "node-blocked-gateway",
    "node-handshake-failed"
  ]

  def enabled? do
    System.get_env("CLAWRIG_ENABLE_PREVIEW_STATES", "false") == "true"
  end

  def allowed_scenarios, do: @allowed_scenarios

  def apply_dashboard(params) when is_map(params) do
    scenario = params["preview"]

    if enabled?() and scenario in @allowed_scenarios do
      %{preview_scenario: scenario}
      |> Map.merge(scenario_overrides(scenario))
    else
      %{preview_scenario: nil}
    end
  end

  defp scenario_overrides("bootstrapping") do
    %{
      gateway_status: :loading,
      internet: :loading,
      openai_status: :loading
    }
  end

  defp scenario_overrides("gateway-down") do
    %{
      gateway_status: :disconnected,
      internet: :connected,
      openai_status: :connected
    }
  end

  defp scenario_overrides("provider-disconnected") do
    %{
      gateway_status: :connected,
      internet: :connected,
      openai_status: :disconnected
    }
  end

  defp scenario_overrides("node-connected") do
    %{
      node_status: :connected,
      node_detail: %{
        status: :connected,
        last_error: nil,
        last_connected_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        last_disconnected_at: nil,
        reconnect_attempts: 0
      },
      node_device_id: "node_live_9f2c1a7b4d3e"
    }
  end

  defp scenario_overrides("node-blocked-gateway") do
    %{
      node_status: :disconnected,
      node_detail: %{
        status: :disconnected,
        last_error: "waiting for gateway to be running",
        last_connected_at: nil,
        last_disconnected_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        reconnect_attempts: 4
      },
      node_device_id: "node_blocked_4b92d1a8e7c3"
    }
  end

  defp scenario_overrides("node-handshake-failed") do
    %{
      node_status: :disconnected,
      node_detail: %{
        status: :disconnected,
        last_error: "rejected: %{\"type\" => \"hello-error\", \"reason\" => \"invalid signature\"}",
        last_connected_at: nil,
        last_disconnected_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        reconnect_attempts: 7
      },
      node_device_id: "node_hs_1d7f5a3c8b2e"
    }
  end
end
