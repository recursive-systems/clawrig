defmodule Clawrig.Fleet.DirectiveProcessorTest do
  use ExUnit.Case, async: false

  alias Clawrig.Fleet.{Ack, DirectiveProcessor}

  setup do
    # Ack is already started by the application supervisor; drain stale entries.
    Ack.drain()

    tmp = Path.join(System.tmp_dir!(), "dp-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "fleet-config.json")
    Application.put_env(:clawrig, :fleet_config_path, path)

    on_exit(fn ->
      Application.delete_env(:clawrig, :fleet_config_path)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  describe "config directive" do
    test "merges config and enqueues success ack" do
      directives = [
        %{"id" => "d-1", "type" => "config", "payload" => %{"update_channel" => "beta"}}
      ]

      DirectiveProcessor.process(directives)

      acks = Ack.drain()
      assert [%{"id" => "d-1", "status" => "success"} | _] = acks
    end
  end

  describe "unknown directive type" do
    test "enqueues unknown_type ack" do
      directives = [
        %{"id" => "d-2", "type" => "bogus"}
      ]

      DirectiveProcessor.process(directives)

      acks = Ack.drain()
      assert [%{"id" => "d-2", "status" => "unknown_type"}] = acks
    end
  end

  describe "malformed directive" do
    test "does not crash when directive has no id" do
      directives = [%{"foo" => "bar"}]

      assert :ok == DirectiveProcessor.process(directives)
      assert Ack.drain() == []
    end
  end
end
