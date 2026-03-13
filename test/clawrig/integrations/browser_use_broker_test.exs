defmodule Clawrig.Integrations.BrowserUseBrokerTest do
  use ExUnit.Case, async: false

  alias Clawrig.Integrations.BrowserUseBroker
  alias Clawrig.TestSupport.MockBrowserUseBrokerHTTP

  setup do
    original_http = Application.get_env(:clawrig, :browser_use_broker_http)
    original_org_slug = Application.get_env(:clawrig, :fleet_org_slug)
    original_org_name = Application.get_env(:clawrig, :fleet_org_name)
    Application.put_env(:clawrig, :browser_use_broker_http, MockBrowserUseBrokerHTTP)
    MockBrowserUseBrokerHTTP.reset()

    on_exit(fn ->
      if original_http,
        do: Application.put_env(:clawrig, :browser_use_broker_http, original_http),
        else: Application.delete_env(:clawrig, :browser_use_broker_http)

      if original_org_slug,
        do: Application.put_env(:clawrig, :fleet_org_slug, original_org_slug),
        else: Application.delete_env(:clawrig, :fleet_org_slug)

      if original_org_name,
        do: Application.put_env(:clawrig, :fleet_org_name, original_org_name),
        else: Application.delete_env(:clawrig, :fleet_org_name)
    end)

    :ok
  end

  test "register_device returns broker payload" do
    Application.put_env(:clawrig, :fleet_org_slug, "acme-hq")
    Application.put_env(:clawrig, :fleet_org_name, "Acme HQ")

    MockBrowserUseBrokerHTTP.put_register_result(
      {:ok, %{status: 201, body: %{"token" => "cbu_dev_123"}}}
    )

    assert {:ok, %{"token" => "cbu_dev_123"}} = BrowserUseBroker.register_device()

    assert %{
             device_id: _,
             hostname: _,
             organization: %{slug: "acme-hq", name: "Acme HQ"}
           } = MockBrowserUseBrokerHTTP.last_register_payload()
  end

  test "get_usage returns managed trial usage" do
    token = "cbu_dev_123"

    MockBrowserUseBrokerHTTP.put_usage_result(
      token,
      {:ok,
       %{
         status: 200,
         body: %{
           "used_usd" => "0.40",
           "remaining_usd" => "2.60",
           "budget_usd" => "3.00",
           "estimated_runs_left" => 13,
           "global_available" => true
         }
       }}
    )

    assert {:ok, %{"estimated_runs_left" => 13, "global_available" => true}} =
             BrowserUseBroker.get_usage(token)
  end

  test "run_task forwards payload through the broker" do
    token = "cbu_dev_123"

    MockBrowserUseBrokerHTTP.put_run_result(
      token,
      {:ok, %{status: 202, body: %{"task_id" => "task_123", "status" => "queued"}}}
    )

    payload = %{"goal" => "Browse example.com", "max_steps" => 15}

    assert {:ok, %{"task_id" => "task_123", "status" => "queued"}} =
             BrowserUseBroker.run_task(token, payload)

    assert payload == MockBrowserUseBrokerHTTP.last_run_payload()
  end
end
