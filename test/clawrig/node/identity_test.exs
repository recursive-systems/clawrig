defmodule Clawrig.Node.IdentityTest do
  use ExUnit.Case, async: true

  alias Clawrig.Node.Identity

  setup do
    path = Path.join(System.tmp_dir!(), "identity-test-#{:rand.uniform(100_000)}.json")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  describe "ensure_keypair/1" do
    test "generates a new keypair when file does not exist", %{path: path} do
      assert {:ok, %{public_key: pub, private_key: priv}} = Identity.ensure_keypair(path)
      assert byte_size(pub) == 32
      assert byte_size(priv) == 32
    end

    test "returns same keypair on second call (idempotent)", %{path: path} do
      {:ok, first} = Identity.ensure_keypair(path)
      {:ok, second} = Identity.ensure_keypair(path)
      assert first.public_key == second.public_key
      assert first.private_key == second.private_key
    end

    test "regenerates if file is corrupted", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not valid json")
      assert {:ok, %{public_key: pub}} = Identity.ensure_keypair(path)
      assert byte_size(pub) == 32
    end
  end

  describe "fingerprint/1" do
    test "returns lowercase hex SHA-256 of public key" do
      {:ok, %{public_key: pub}} =
        Identity.ensure_keypair(
          Path.join(System.tmp_dir!(), "fp-test-#{:rand.uniform(100_000)}.json")
        )

      fp = Identity.fingerprint(pub)
      assert String.length(fp) == 64
      assert fp =~ ~r/^[0-9a-f]+$/
    end
  end

  describe "sign_challenge/3" do
    test "produces a verifiable signature", %{path: path} do
      {:ok, %{public_key: pub, private_key: priv}} = Identity.ensure_keypair(path)

      nonce = Base.encode64(:crypto.strong_rand_bytes(32))
      {:ok, signature_b64, payload} = Identity.sign_challenge(nonce, priv)

      assert Identity.verify(signature_b64, payload, pub) == true
    end

    test "includes v3 payload fields", %{path: path} do
      {:ok, %{private_key: priv}} = Identity.ensure_keypair(path)

      {:ok, _sig, payload} = Identity.sign_challenge("test-nonce", priv, role: "node")
      decoded = Jason.decode!(payload)

      assert decoded["v"] == 3
      assert decoded["nonce"] == "test-nonce"
      assert decoded["platform"] == "linux"
      assert decoded["deviceFamily"] == "pi"
      assert decoded["role"] == "node"
      assert is_integer(decoded["signedAt"])
    end

    test "signature fails with wrong public key", %{path: path} do
      {:ok, %{private_key: priv}} = Identity.ensure_keypair(path)
      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, sig, payload} = Identity.sign_challenge("nonce", priv)
      assert Identity.verify(sig, payload, other_pub) == false
    end
  end
end
