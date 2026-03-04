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
end
