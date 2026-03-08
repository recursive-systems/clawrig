defmodule Clawrig.UpdaterTest do
  use ExUnit.Case, async: true

  alias Clawrig.Updater

  describe "parse_manifest/1" do
    test "parses valid manifest" do
      manifest = %{
        "version" => "0.2.0",
        "tarball" => "clawrig.tar.gz",
        "signature" => "base64sig",
        "checksum" => "abc123",
        "released_at" => "2026-03-02T12:00:00Z"
      }

      assert {:ok, parsed} = Updater.parse_manifest(manifest)
      assert parsed.version == "0.2.0"
      assert parsed.checksum == "abc123"
    end

    test "rejects manifest missing required fields" do
      assert {:error, _} = Updater.parse_manifest(%{"version" => "0.1.0"})
    end
  end

  describe "version_newer?/2" do
    test "detects newer version" do
      assert Updater.version_newer?("0.2.0", "0.1.0")
    end

    test "rejects same version" do
      refute Updater.version_newer?("0.1.0", "0.1.0")
    end

    test "rejects older version" do
      refute Updater.version_newer?("0.1.0", "0.2.0")
    end
  end

  describe "auto_update_enabled?/0" do
    test "returns true by default" do
      assert Updater.auto_update_enabled?()
    end
  end

  describe "parse_pending_marker_public/1" do
    test "parses json pending marker with mode" do
      marker = Jason.encode!(%{"version" => "5.4.0", "mode" => "manual"})

      assert %{version: "5.4.0", mode: :manual} = Updater.parse_pending_marker_public(marker)
    end

    test "falls back to legacy plain version marker" do
      assert %{version: "5.4.0", mode: :auto} = Updater.parse_pending_marker_public("5.4.0\n")
    end
  end

  describe "classify_update_risk_public/2" do
    test "classifies patch updates as safe" do
      assert Updater.classify_update_risk_public("1.2.4", "1.2.3") == :safe
    end

    test "classifies minor updates as guarded" do
      assert Updater.classify_update_risk_public("1.3.0", "1.2.9") == :guarded
    end

    test "classifies major updates as breaking" do
      assert Updater.classify_update_risk_public("2.0.0", "1.9.9") == :breaking
    end
  end

  describe "post_update_auth_probe_public/1" do
    setup do
      auth_path = Path.join(System.tmp_dir!(), "clawrig-test-auth-profiles-probe-#{System.unique_integer([:positive])}.json")
      home = Path.join(System.tmp_dir!(), "clawrig-test-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(home, ".codex"))

      old_home = System.get_env("HOME")
      System.put_env("HOME", home)
      Application.put_env(:clawrig, :auth_profiles_path, auth_path)

      on_exit(fn ->
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
        Application.delete_env(:clawrig, :auth_profiles_path)
        File.rm_rf(home)
        File.rm(auth_path)
      end)

      %{auth_path: auth_path, home: home}
    end

    test "returns reauth required when no auth files exist" do
      assert Updater.post_update_auth_probe_public("5.4.0") == {:error, :reauth_required}
    end

    test "returns ok when auth files exist and model status succeeds", %{auth_path: auth_path, home: home} do
      File.write!(auth_path, Jason.encode!(%{
        "version" => 1,
        "profiles" => %{
          "openai-codex:default" => %{"provider" => "openai-codex", "refresh" => "refresh-token"}
        }
      }))

      File.write!(Path.join([home, ".codex", "auth.json"]), Jason.encode!(%{"auth_mode" => "chatgpt"}))

      assert Updater.post_update_auth_probe_public("5.4.0") == :ok
    end
  end
end
