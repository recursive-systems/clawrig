defmodule Clawrig.Gateway.OperatorStore do
  @moduledoc false

  alias Clawrig.Node.Identity, as: NodeIdentity

  def path do
    Application.get_env(
      :clawrig,
      :gateway_operator_store_path,
      "/var/lib/clawrig/gateway-operator.json"
    )
  end

  def identity do
    data = ensure_keypair()

    %{
      public_key: decode64(data["public_key"]),
      private_key: decode64(data["private_key"]),
      device_id: NodeIdentity.fingerprint(decode64(data["public_key"])),
      device_token: data["device_token"]
    }
  end

  def put_device_token(device_token) when is_binary(device_token) and device_token != "" do
    data =
      ensure_keypair()
      |> Map.put("device_token", device_token)
      |> Map.put("paired_at", now_iso())
      |> Map.put("updated_at", now_iso())

    write(data)
  end

  def clear_device_token do
    data =
      ensure_keypair()
      |> Map.delete("device_token")
      |> Map.put("updated_at", now_iso())

    write(data)
  end

  defp ensure_keypair do
    case read() do
      %{"public_key" => pub, "private_key" => priv} when is_binary(pub) and is_binary(priv) ->
        read()

      _ ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

        data = %{
          "public_key" => Base.encode64(pub),
          "private_key" => Base.encode64(priv),
          "generated_at" => now_iso()
        }

        write(data)
        data
    end
  end

  defp decode64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> raise "Invalid base64 gateway operator store"
    end
  end

  defp read do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write(data) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(data, pretty: true) <> "\n")
    _ = File.chmod(path(), 0o600)
    :ok
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
