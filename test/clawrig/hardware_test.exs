defmodule Clawrig.HardwareTest do
  use ExUnit.Case, async: false

  alias Clawrig.Hardware

  setup do
    tmp = Path.join(System.tmp_dir!(), "hw-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    model_path = Path.join(tmp, "model")

    Application.put_env(:clawrig, :device_tree_model_path, model_path)

    on_exit(fn ->
      Application.delete_env(:clawrig, :device_tree_model_path)
      File.rm_rf(tmp)
    end)

    %{model_path: model_path}
  end

  test "detects Pi 4 Model B", %{model_path: path} do
    File.write!(path, "Raspberry Pi 4 Model B\0")
    assert {:ok, "rpi4"} = Hardware.compat_code()
  end

  test "detects Pi 5", %{model_path: path} do
    File.write!(path, "Raspberry Pi 5\0")
    assert {:ok, "rpi5"} = Hardware.compat_code()
  end

  test "detects Pi 400 as rpi4", %{model_path: path} do
    File.write!(path, "Raspberry Pi 400\0")
    assert {:ok, "rpi4"} = Hardware.compat_code()
  end

  test "returns error for unknown model", %{model_path: path} do
    File.write!(path, "Unknown Board\0")
    assert {:error, {:unknown_model, "Unknown Board"}} = Hardware.compat_code()
  end

  test "returns error when file missing" do
    Application.put_env(:clawrig, :device_tree_model_path, "/nonexistent/path")
    assert {:error, {:read_failed, :enoent}} = Hardware.compat_code()
  end
end
