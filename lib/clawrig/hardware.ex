defmodule Clawrig.Hardware do
  @moduledoc "Detect Raspberry Pi hardware model for OTA compatibility."

  @device_tree_path "/proc/device-tree/model"

  @model_to_compat %{
    "Raspberry Pi 4 Model B" => "rpi4",
    "Raspberry Pi 400" => "rpi4",
    "Raspberry Pi Compute Module 4" => "rpi4",
    "Raspberry Pi Compute Module 4S" => "rpi4",
    "Raspberry Pi 5" => "rpi5",
    "Raspberry Pi Compute Module 5" => "rpi5",
    "Raspberry Pi Zero 2 W" => "rpi02w"
  }

  @doc """
  Returns the hardware compatibility code for this device.

  Reads `/proc/device-tree/model`, strips the trailing null byte,
  and maps to a short code like `"rpi4"` or `"rpi5"`.

  Returns `{:ok, code}` or `{:error, reason}`.
  """
  def compat_code do
    path = Application.get_env(:clawrig, :device_tree_model_path, @device_tree_path)

    case File.read(path) do
      {:ok, raw} ->
        model = raw |> String.trim_trailing(<<0>>) |> String.trim()

        case Map.fetch(@model_to_compat, model) do
          {:ok, code} ->
            {:ok, code}

          :error ->
            fallback =
              Enum.find_value(@model_to_compat, fn {prefix, code} ->
                if String.starts_with?(model, prefix), do: code
              end)

            case fallback do
              nil -> {:error, {:unknown_model, model}}
              code -> {:ok, code}
            end
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end
end
