defmodule Clawrig.Fleet.DirectiveProcessor do
  @moduledoc """
  Processes fleet directives received in heartbeat responses.

  Directive types:
  - `config` — Persistent configuration (pause_updates, channel). Merged to disk.
  - `action` — One-shot commands (force_check, reboot, identify). Executed once.
  """

  require Logger

  def process(directives) when is_list(directives) do
    Enum.each(directives, fn directive ->
      try do
        handle(directive)
      rescue
        e ->
          id = directive["id"] || "unknown"
          Logger.error("[Fleet] directive #{id} crashed: #{Exception.message(e)}")
          if is_binary(directive["id"]), do: Clawrig.Fleet.Ack.enqueue(directive["id"], :crash)
      end
    end)
  end

  defp handle(%{"id" => id, "type" => "config", "payload" => payload}) do
    Logger.info("[Fleet] processing config directive #{id}: #{inspect(payload)}")

    case Clawrig.Fleet.Config.merge(payload) do
      :ok ->
        Clawrig.Fleet.Ack.enqueue(id, :success)

      {:error, reason} ->
        Logger.error("[Fleet] config directive #{id} failed to persist: #{inspect(reason)}")
        Clawrig.Fleet.Ack.enqueue(id, :failure)
    end
  end

  defp handle(%{"id" => id, "type" => "action", "payload" => %{"action" => "force_check"}}) do
    Logger.info("[Fleet] processing action directive #{id}: force_check")
    Clawrig.Updater.check_now()
    Clawrig.Fleet.Ack.enqueue(id, :success)
  rescue
    e ->
      Logger.error("[Fleet] force_check failed: #{Exception.message(e)}")
      Clawrig.Fleet.Ack.enqueue(id, :failure)
  end

  defp handle(%{"id" => id, "type" => "action", "payload" => %{"action" => "reboot"}}) do
    Logger.info("[Fleet] processing action directive #{id}: reboot")
    Clawrig.Fleet.Ack.enqueue(id, :success)

    Task.Supervisor.start_child(Clawrig.TaskSupervisor, fn ->
      Process.sleep(5_000)
      System.cmd("sudo", ["reboot"])
    end)
  end

  defp handle(%{"id" => id, "type" => "action", "payload" => %{"action" => "identify"}}) do
    Logger.info("[Fleet] processing action directive #{id}: identify")
    Logger.notice("[Fleet] === IDENTIFY: This device was identified by fleet command ===")
    Clawrig.Fleet.Ack.enqueue(id, :success)
  end

  defp handle(%{"id" => id, "type" => type}) do
    Logger.warning("[Fleet] unknown directive type: #{type}")
    Clawrig.Fleet.Ack.enqueue(id, :unknown_type)
  end

  defp handle(invalid) do
    Logger.warning("[Fleet] malformed directive (missing id/type): #{inspect(invalid)}")

    case invalid do
      %{"id" => id} -> Clawrig.Fleet.Ack.enqueue(id, :malformed)
      _ -> :ok
    end
  end
end
