defmodule Clawrig.OpenAI.CredentialsTest do
  use ExUnit.Case, async: true

  alias Clawrig.OpenAI.Credentials

  setup do
    path = Path.join(System.tmp_dir!(), "clawrig-test-auth-profiles-#{System.unique_integer([:positive])}.json")
    Application.put_env(:clawrig, :auth_profiles_path, path)

    on_exit(fn ->
      Application.delete_env(:clawrig, :auth_profiles_path)
      File.rm(path)
    end)

    %{path: path}
  end

  test "auth_configured? is false when no auth profiles exist" do
    refute Credentials.auth_configured?()
  end

  test "auth_configured? is true when openai-codex oauth profile with refresh exists", %{path: path} do
    File.write!(path, Jason.encode!(%{
      "version" => 1,
      "profiles" => %{
        "openai-codex:default" => %{
          "provider" => "openai-codex",
          "refresh" => "refresh-token"
        }
      }
    }))

    assert Credentials.auth_configured?()
  end

  test "auth_configured? ignores unrelated or incomplete profiles", %{path: path} do
    File.write!(path, Jason.encode!(%{
      "version" => 1,
      "profiles" => %{
        "other" => %{"provider" => "openai", "refresh" => "x"},
        "broken" => %{"provider" => "openai-codex", "refresh" => ""}
      }
    }))

    refute Credentials.auth_configured?()
  end
end
