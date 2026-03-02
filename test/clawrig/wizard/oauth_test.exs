defmodule Clawrig.Wizard.OAuthTest do
  use ExUnit.Case, async: true

  alias Clawrig.Wizard.OAuth

  test "generate_pkce returns verifier and challenge" do
    {verifier, challenge} = OAuth.generate_pkce()
    assert is_binary(verifier)
    assert is_binary(challenge)
    assert verifier != challenge
    assert byte_size(verifier) > 20
    assert byte_size(challenge) > 20
  end

  test "build_auth_url generates valid URL" do
    {_verifier, challenge} = OAuth.generate_pkce()
    url = OAuth.build_auth_url("test-state", challenge)

    assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize?")
    assert String.contains?(url, "client_id=")
    assert String.contains?(url, "state=test-state")
    assert String.contains?(url, "code_challenge=")
    assert String.contains?(url, "originator=pi")
  end

  test "connected? returns false for nil" do
    assert OAuth.connected?(nil) == false
  end

  test "connected? returns true for valid tokens" do
    tokens = %{
      access: "test-access-token",
      refresh: "test-refresh-token",
      expires: System.system_time(:millisecond) + 3_600_000,
      account_id: "test-account"
    }

    assert OAuth.connected?(tokens) == true
  end

  test "connected? returns true with expired access but valid refresh" do
    tokens = %{
      access: "test-access-token",
      refresh: "test-refresh-token",
      expires: System.system_time(:millisecond) - 1000,
      account_id: "test-account"
    }

    assert OAuth.connected?(tokens) == true
  end

  test "ensure_fresh returns tokens if not expired" do
    tokens = %{
      access: "test-access-token",
      refresh: "test-refresh-token",
      expires: System.system_time(:millisecond) + 3_600_000,
      account_id: "test-account"
    }

    assert {:ok, ^tokens} = OAuth.ensure_fresh(tokens)
  end

  test "ensure_fresh returns error for nil" do
    assert {:error, _} = OAuth.ensure_fresh(nil)
  end
end
