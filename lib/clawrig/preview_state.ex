defmodule Clawrig.PreviewState do
  @moduledoc """
  Dev-only preview scenario injector.

  Disabled by default. Enable with `CLAWRIG_ENABLE_PREVIEW_STATES=true`.
  """

  @allowed_scenarios ["bootstrapping", "gateway-down", "provider-disconnected"]

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
end
