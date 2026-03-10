defmodule Clawrig.Fleet.PayloadTest do
  use ExUnit.Case, async: true

  alias Clawrig.Fleet.Payload

  setup do
    original_commands = Application.get_env(:clawrig, :system_commands)
    original_org_slug = Application.get_env(:clawrig, :fleet_org_slug)
    original_org_name = Application.get_env(:clawrig, :fleet_org_name)
    original_site_code = Application.get_env(:clawrig, :fleet_site_code)
    original_site_name = Application.get_env(:clawrig, :fleet_site_name)

    Application.put_env(:clawrig, :system_commands, Clawrig.System.MockCommands)
    Application.put_env(:clawrig, :fleet_org_slug, "acme-corp")
    Application.put_env(:clawrig, :fleet_org_name, "Acme Corp")
    Application.put_env(:clawrig, :fleet_site_code, "hq")
    Application.put_env(:clawrig, :fleet_site_name, "HQ")

    on_exit(fn ->
      restore_env(:system_commands, original_commands)
      restore_env(:fleet_org_slug, original_org_slug)
      restore_env(:fleet_org_name, original_org_name)
      restore_env(:fleet_site_code, original_site_code)
      restore_env(:fleet_site_name, original_site_name)
    end)

    :ok
  end

  test "build returns generic heartbeat payload with required sections" do
    payload = Payload.build()

    assert payload["organization"]["slug"] == "acme-corp"
    assert payload["organization"]["name"] == "Acme Corp"

    assert payload["site"]["code"] == "hq"
    assert payload["site"]["name"] == "HQ"

    assert is_binary(payload["device"]["uid"])
    assert is_binary(payload["device"]["hostname"])

    assert payload["metrics"]["gateway_status"] == "running"
    assert payload["metrics"]["internet_ok"] == true
    assert payload["health_summary"] == "healthy"

    assert is_binary(payload["observed_at"])

    assert payload["versions"]["clawrig"] in ["0.0.0-dev", "dev"] or
             is_binary(payload["versions"]["clawrig"])
  end

  defp restore_env(key, nil), do: Application.delete_env(:clawrig, key)
  defp restore_env(key, value), do: Application.put_env(:clawrig, key, value)
end
