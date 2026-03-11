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
      tmp = Path.join(System.tmp_dir!(), "clawrig-test-probe-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      auth_profiles_path = Path.join(tmp, "auth-profiles.json")
      codex_auth_path = Path.join(tmp, "auth.json")

      Application.put_env(:clawrig, :auth_profiles_path, auth_profiles_path)
      Application.put_env(:clawrig, :codex_auth_path, codex_auth_path)

      on_exit(fn ->
        Application.delete_env(:clawrig, :auth_profiles_path)
        Application.delete_env(:clawrig, :codex_auth_path)
        File.rm_rf(tmp)
      end)

      %{auth_profiles_path: auth_profiles_path, codex_auth_path: codex_auth_path}
    end

    test "returns reauth required when no auth files exist" do
      assert Updater.post_update_auth_probe_public("5.4.0") == {:error, :reauth_required}
    end

    test "returns ok when auth files exist and model status succeeds", %{
      auth_profiles_path: auth_profiles_path,
      codex_auth_path: codex_auth_path
    } do
      File.write!(
        auth_profiles_path,
        Jason.encode!(%{
          "version" => 1,
          "profiles" => %{
            "openai-codex:default" => %{
              "provider" => "openai-codex",
              "refresh" => "refresh-token"
            }
          }
        })
      )

      File.write!(
        codex_auth_path,
        Jason.encode!(%{"auth_mode" => "chatgpt"})
      )

      assert Updater.post_update_auth_probe_public("5.4.0") == :ok
    end
  end

  describe "retry_allowed_public?/1" do
    test "allows retries below limit" do
      assert Updater.retry_allowed_public?(0)
      assert Updater.retry_allowed_public?(1)
    end

    test "blocks retries at or above limit" do
      refute Updater.retry_allowed_public?(Updater.max_retry_attempts())
      refute Updater.retry_allowed_public?(Updater.max_retry_attempts() + 1)
    end
  end

  describe "reconcile_outcome_public/3" do
    test "auto update with auth required rolls back" do
      assert Updater.reconcile_outcome_public(:auto, true, {:error, :reauth_required}) ==
               :rolled_back_auth_required
    end

    test "manual update with auth required requests reauth post update" do
      assert Updater.reconcile_outcome_public(:manual, true, {:error, :reauth_required}) ==
               :pending_reauth_post_update
    end

    test "healthy service and auth passes updates successfully" do
      assert Updater.reconcile_outcome_public(:manual, true, :ok) == :updated
    end

    test "unhealthy service fails reconciliation regardless of mode" do
      assert Updater.reconcile_outcome_public(:auto, false, :ok) == :health_failed
    end
  end

  describe "simulate_reconcile_public/4" do
    test "simulates auto update rollback path" do
      assert Updater.simulate_reconcile_public(:auto, "5.4.0", true, {:error, :reauth_required}) ==
               %{
                 status: :rolled_back_auth_required,
                 version: "5.4.0",
                 rollback: true,
                 resume_reason: :rolled_back_auth_required
               }
    end

    test "simulates manual update pending reauth path" do
      assert Updater.simulate_reconcile_public(:manual, "5.4.0", true, {:error, :reauth_required}) ==
               %{
                 status: :pending_reauth_post_update,
                 version: "5.4.0",
                 rollback: false,
                 resume_reason: :pending_reauth_post_update
               }
    end

    test "simulates clean update success" do
      assert Updater.simulate_reconcile_public(:manual, "5.4.0", true, :ok) == %{
               status: :updated,
               version: "5.4.0",
               rollback: false,
               resume_reason: nil
             }
    end

    test "simulates service health failure" do
      assert Updater.simulate_reconcile_public(
               :manual,
               "5.4.0",
               false,
               {:error, :service_unhealthy}
             ) == %{
               status: :health_failed,
               version: "5.4.0",
               rollback: true,
               resume_reason: nil
             }
    end
  end
end
