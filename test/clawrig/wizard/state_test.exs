defmodule Clawrig.Wizard.StateTest do
  use ExUnit.Case

  alias Clawrig.Wizard.State

  setup do
    # Reset state before each test
    State.reset()
    :ok
  end

  test "get returns default state" do
    state = State.get()
    assert state.step == :preflight
    assert state.mode == :new
    assert state.preflight_done == false
  end

  test "get returns state with schema_version" do
    state = State.get()
    assert state.schema_version == 1
  end

  test "put updates a single key" do
    State.put(:mode, :new)
    assert State.get(:mode) == :new
  end

  test "merge updates multiple keys" do
    State.merge(%{mode: :restore, preflight_done: true})
    state = State.get()
    assert state.mode == :restore
    assert state.preflight_done == true
  end

  test "reset returns to defaults" do
    State.put(:step, :install)
    State.put(:preflight_done, true)
    State.reset()

    state = State.get()
    assert state.mode == :new
    assert state.step == :preflight
    assert state.preflight_done == false
  end
end
