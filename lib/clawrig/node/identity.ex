defmodule Clawrig.Node.Identity do
  @moduledoc """
  Manages Ed25519 keypair for the OpenClaw Gateway node protocol.

  The keypair is generated once and persisted to disk. The public key's
  SHA-256 fingerprint becomes the device ID in the Gateway protocol.
  """

  @doc """
  Returns the configured identity file path.
  """
  def identity_path do
    Application.get_env(:clawrig, :node_identity_path, "priv/node-identity.json")
  end

  @doc """
  Reads or generates an Ed25519 keypair at `path`.

  Returns `{:ok, %{public_key: binary(), private_key: binary()}}` or
  `{:error, reason}`.
  """
  def ensure_keypair(path \\ nil) do
    path = path || identity_path()

    case read_keypair(path) do
      {:ok, keypair} -> {:ok, keypair}
      {:error, _} -> generate_and_persist(path)
    end
  end

  @doc """
  Returns the SHA-256 hex fingerprint of a raw public key.

  This becomes the `device.id` in the Gateway protocol.
  """
  def fingerprint(public_key) when is_binary(public_key) do
    :crypto.hash(:sha256, public_key) |> Base.encode16(case: :lower)
  end

  @doc """
  Signs a challenge nonce for the Gateway handshake (v3 payload).

  The signed payload binds: nonce, platform, deviceFamily, role, scopes,
  and a timestamp to prevent replay attacks.
  """
  def sign_challenge(nonce, private_key, opts \\ []) do
    payload =
      %{
        "v" => 3,
        "nonce" => nonce,
        "platform" => Keyword.get(opts, :platform, "linux"),
        "deviceFamily" => Keyword.get(opts, :device_family, "pi"),
        "role" => Keyword.get(opts, :role, "node"),
        "scopes" => Keyword.get(opts, :scopes, []),
        "signedAt" => System.system_time(:millisecond)
      }
      |> Jason.encode!()

    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    {:ok, Base.encode64(signature), payload}
  end

  @doc """
  Verifies a signature against a payload using the public key.
  """
  def verify(signature_b64, payload, public_key) do
    with {:ok, signature} <- Base.decode64(signature_b64) do
      :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
    end
  end

  # --- Private ---

  defp read_keypair(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         {:ok, pub} <- Base.decode64(data["public_key"]),
         {:ok, priv} <- Base.decode64(data["private_key"]) do
      {:ok, %{public_key: pub, private_key: priv}}
    end
  end

  defp generate_and_persist(path) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    json =
      Jason.encode!(%{
        "public_key" => Base.encode64(pub),
        "private_key" => Base.encode64(priv),
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)

    {:ok, %{public_key: pub, private_key: priv}}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
