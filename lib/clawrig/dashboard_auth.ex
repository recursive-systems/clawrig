defmodule Clawrig.DashboardAuth do
  @moduledoc "Local dashboard password auth storage/verification."

  @min_length 8
  @iterations 20_000

  def configured? do
    case read_auth() do
      %{"salt" => _s, "hash" => _h} -> true
      _ -> false
    end
  end

  def min_length, do: @min_length

  def set_password(password) when is_binary(password) do
    with :ok <- validate_password(password) do
      salt = :crypto.strong_rand_bytes(16) |> Base.encode64()
      hash = derive_hash(password, salt)
      write_auth(%{"salt" => salt, "hash" => hash, "updated_at" => now_iso()})
    end
  end

  def verify_password(password) when is_binary(password) do
    case read_auth() do
      %{"salt" => salt, "hash" => stored_hash} ->
        Plug.Crypto.secure_compare(derive_hash(password, salt), stored_hash)

      _ ->
        false
    end
  end

  def change_password(current_password, new_password) do
    if verify_password(current_password) do
      set_password(new_password)
    else
      {:error, "Current password is incorrect"}
    end
  end

  def password_strength(password) when is_binary(password) do
    score =
      0 +
        if(String.length(password) >= 8, do: 1, else: 0) +
        if(String.length(password) >= 12, do: 1, else: 0) +
        if(String.match?(password, ~r/[A-Z]/), do: 1, else: 0) +
        if(String.match?(password, ~r/[a-z]/), do: 1, else: 0) +
        if(String.match?(password, ~r/[0-9]/), do: 1, else: 0) +
        if(String.match?(password, ~r/[^A-Za-z0-9]/), do: 1, else: 0)

    cond do
      score >= 5 -> :strong
      score >= 3 -> :medium
      true -> :weak
    end
  end

  defp validate_password(password) do
    if String.length(password) < @min_length do
      {:error, "Password must be at least #{@min_length} characters"}
    else
      :ok
    end
  end

  defp derive_hash(password, salt) do
    seed = salt <> password

    Enum.reduce(1..@iterations, seed, fn _, acc ->
      :crypto.hash(:sha256, acc) |> Base.encode16(case: :lower)
    end)
  end

  defp auth_path do
    Application.get_env(:clawrig, :dashboard_auth_path, "/var/lib/clawrig/dashboard-auth.json")
  end

  defp read_auth do
    case File.read(auth_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_auth(map) do
    File.mkdir_p!(Path.dirname(auth_path()))
    File.write(auth_path(), Jason.encode!(map, pretty: true) <> "\n")
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
