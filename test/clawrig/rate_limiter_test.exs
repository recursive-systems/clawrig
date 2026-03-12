defmodule Clawrig.RateLimiterTest do
  use ExUnit.Case, async: true

  setup do
    # Each test gets a fresh state by using a unique IP
    ip = "test-#{System.unique_integer([:positive])}"
    {:ok, ip: ip}
  end

  test "allows requests under the limit", %{ip: ip} do
    assert :ok = Clawrig.RateLimiter.check(ip)
  end

  test "blocks after 5 failures", %{ip: ip} do
    for _ <- 1..5, do: Clawrig.RateLimiter.record_failure(ip)
    assert :blocked = Clawrig.RateLimiter.check(ip)
  end

  test "reset clears failures", %{ip: ip} do
    for _ <- 1..5, do: Clawrig.RateLimiter.record_failure(ip)
    assert :blocked = Clawrig.RateLimiter.check(ip)
    Clawrig.RateLimiter.reset(ip)
    assert :ok = Clawrig.RateLimiter.check(ip)
  end

  test "4 failures still allows", %{ip: ip} do
    for _ <- 1..4, do: Clawrig.RateLimiter.record_failure(ip)
    assert :ok = Clawrig.RateLimiter.check(ip)
  end
end
