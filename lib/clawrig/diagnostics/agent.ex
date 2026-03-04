defmodule Clawrig.Diagnostics.Agent do
  @moduledoc """
  Layer 2.5: AI-powered diagnostic agent using Codex CLI.

  Runs every 15 minutes after OOBE completes. Collects system state
  (gateway status, journal errors, disk space) and asks Codex to
  recommend a repair action from a strict allowlist.

  Uses the same OAuth tokens the user provided during OOBE — no
  additional API keys or operator credentials required.

  Starts in dry-run mode (log recommendations, don't execute).
  """

  use GenServer
  require Logger

  alias Clawrig.System.Commands

  @check_interval :timer.minutes(15)
  @schema_path Application.compile_env(
                 :clawrig,
                 :diagnostic_schema_path,
                 "priv/diagnostic-schema.json"
               )
  @audit_log_path "/var/lib/clawrig/diagnostic-audit.log"
  @allowed_actions ~w(none restart_gateway run_doctor clear_tmp reinstall_openclaw reboot escalate)
  @max_actions_per_hour 4
  @min_confidence 0.7

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a diagnostic check now."
  def check_now do
    GenServer.call(__MODULE__, :check_now, 120_000)
  end

  @doc "Return recent diagnostic history."
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc "Enable or disable dry-run mode."
  def set_dry_run(enabled) when is_boolean(enabled) do
    GenServer.call(__MODULE__, {:set_dry_run, enabled})
  end

  @doc "Returns true if dry-run mode is active."
  def dry_run? do
    Clawrig.Wizard.State.get(:diagnostics_dry_run) != false
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      last_check: nil,
      last_result: nil,
      history: [],
      actions_this_hour: 0,
      hour_start: System.system_time(:second)
    }

    if oobe_complete?() and codex_available?() do
      schedule_check()

      Logger.info(
        "[Diagnostics] Scheduled checks every #{div(@check_interval, 60_000)}m (dry_run=#{dry_run?()})"
      )
    else
      reason =
        cond do
          !oobe_complete?() -> "OOBE not complete"
          !codex_available?() -> "Codex CLI not found"
        end

      Logger.info("[Diagnostics] #{reason} — diagnostic checks disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    {result, state} = do_diagnostic(state)
    {:reply, result, state}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call({:set_dry_run, enabled}, _from, state) do
    Clawrig.Wizard.State.put(:diagnostics_dry_run, enabled)
    Logger.info("[Diagnostics] Dry-run mode #{if enabled, do: "enabled", else: "disabled"}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    if oobe_complete?() and codex_available?() do
      {_result, state} = do_diagnostic(state)
      schedule_check()
      {:noreply, state}
    else
      schedule_check()
      {:noreply, state}
    end
  end

  # ── Diagnostic Flow ─────────────────────────────────────────────

  defp do_diagnostic(state) do
    state = maybe_reset_rate_limit(state)
    snapshot = collect_snapshot()
    prompt = build_prompt(snapshot)
    schema = schema_path()

    case Commands.impl().run_codex_exec(prompt, schema) do
      {output, 0} ->
        handle_codex_response(output, state)

      {output, code} ->
        Logger.warning(
          "[Diagnostics] codex exec failed (exit #{code}): #{String.slice(output, 0..200)}"
        )

        result = {:error, :codex_failed}
        state = %{state | last_check: DateTime.utc_now(), last_result: result}
        {result, state}
    end
  end

  defp handle_codex_response(output, state) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"action" => action, "reason" => reason, "confidence" => confidence}}
      when action in @allowed_actions ->
        result = %{action: action, reason: reason, confidence: confidence}
        execute_or_log(result, state)

      {:ok, resp} ->
        Logger.warning("[Diagnostics] Invalid response from Codex: #{inspect(resp)}")
        result = {:error, :invalid_response}
        state = %{state | last_check: DateTime.utc_now(), last_result: result}
        {result, state}

      {:error, _} ->
        Logger.warning("[Diagnostics] Failed to parse Codex output as JSON")
        result = {:error, :parse_failed}
        state = %{state | last_check: DateTime.utc_now(), last_result: result}
        {result, state}
    end
  end

  defp execute_or_log(%{action: "none"} = result, state) do
    audit_log(result, :healthy)
    state = record_result(result, state)
    {{:ok, result}, state}
  end

  defp execute_or_log(%{confidence: conf} = result, state) when conf < @min_confidence do
    audit_log(result, :low_confidence)

    Logger.info(
      "[Diagnostics] Low confidence (#{conf}), skipping: #{result.action} — #{result.reason}"
    )

    state = record_result(result, state)
    {{:ok, :low_confidence}, state}
  end

  defp execute_or_log(result, state) do
    if dry_run?() do
      audit_log(result, :dry_run)
      Logger.info("[Diagnostics] DRY RUN: would #{result.action} — #{result.reason}")
      broadcast({:dry_run, result.action, result.reason})
      state = record_result(result, state)
      {{:ok, :dry_run}, state}
    else
      if state.actions_this_hour >= @max_actions_per_hour do
        audit_log(result, :rate_limited)
        Logger.warning("[Diagnostics] Rate limited, skipping #{result.action}")
        state = record_result(result, state)
        {{:ok, :rate_limited}, state}
      else
        audit_log(result, :executing)
        do_execute(result.action)
        broadcast({:executed, result.action, result.reason})
        state = %{record_result(result, state) | actions_this_hour: state.actions_this_hour + 1}
        {{:ok, :executed}, state}
      end
    end
  end

  # ── Action Execution ────────────────────────────────────────────

  defp do_execute("restart_gateway") do
    Logger.info("[Diagnostics] Executing: restart_gateway")
    Commands.impl().start_gateway()
  end

  defp do_execute("run_doctor") do
    Logger.info("[Diagnostics] Executing: run_doctor")
    Commands.impl().run_openclaw(["doctor", "--fix"])
  end

  defp do_execute("clear_tmp") do
    Logger.info("[Diagnostics] Executing: clear_tmp")

    System.cmd(
      "find",
      ["/tmp/openclaw", "-maxdepth", "1", "-type", "f", "-mtime", "+1", "-delete"],
      stderr_to_stdout: true
    )
  end

  defp do_execute("reinstall_openclaw") do
    Logger.info("[Diagnostics] Executing: reinstall_openclaw")
    Commands.impl().install_gateway()
    Commands.impl().start_gateway()
  end

  defp do_execute("reboot") do
    Logger.warning("[Diagnostics] Executing: reboot")
    System.cmd("sudo", ["systemctl", "reboot"], stderr_to_stdout: true)
  end

  defp do_execute("escalate") do
    Logger.warning("[Diagnostics] ESCALATION: manual intervention needed")
    broadcast(:escalation_needed)
  end

  # ── Data Collection ─────────────────────────────────────────────

  defp collect_snapshot do
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      gateway: collect_gateway_status(),
      journal_errors: collect_recent_errors(),
      disk: collect_disk_info(),
      uptime: collect_uptime()
    }
  end

  defp collect_gateway_status do
    case Commands.impl().gateway_status() do
      :running -> "running"
      :stopped -> "stopped"
    end
  end

  defp collect_recent_errors do
    case System.cmd(
           "journalctl",
           [
             "-u",
             "clawrig",
             "-u",
             "openclaw-gateway",
             "--since",
             "15 min ago",
             "-p",
             "err",
             "--no-pager",
             "-q",
             "-n",
             "30"
           ],
           stderr_to_stdout: true
         ) do
      {output, _} -> String.trim(output)
    end
  rescue
    _ -> "unavailable"
  end

  defp collect_disk_info do
    case System.cmd("df", ["/opt/clawrig", "--output=avail,pcent"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp collect_uptime do
    case System.cmd("uptime", ["-p"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  # ── Prompt Construction ─────────────────────────────────────────

  defp build_prompt(snapshot) do
    """
    You are a ClawRig device diagnostic agent running on a Raspberry Pi.
    Analyze the system state below and recommend exactly ONE action.

    Choose "none" if the system is healthy. Only recommend an action if
    there is a clear problem. Be conservative — false positives cause
    unnecessary restarts.

    Allowed actions:
    - none: System is healthy, no action needed
    - restart_gateway: Restart the OpenClaw gateway service
    - run_doctor: Run openclaw doctor --fix to repair configuration
    - clear_tmp: Clean stale temporary files
    - reinstall_openclaw: Reinstall and restart the OpenClaw gateway
    - reboot: Reboot the entire device (last resort)
    - escalate: Flag for human intervention (unrecoverable issue)

    System state:
    #{Jason.encode!(snapshot, pretty: true)}
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp schedule_check do
    Process.send_after(self(), :scheduled_check, @check_interval)
  end

  defp oobe_complete? do
    File.exists?(Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete"))
  end

  defp codex_available? do
    match?({_, 0}, System.cmd("which", ["codex"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp schema_path do
    if File.exists?(@schema_path) do
      @schema_path
    else
      Application.app_dir(:clawrig, @schema_path)
    end
  end

  defp broadcast(status) do
    Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:diagnostics", {:diagnostic_status, status})
  end

  defp record_result(result, state) do
    entry = Map.put(result, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
    history = Enum.take([entry | state.history], 50)
    %{state | last_check: DateTime.utc_now(), last_result: result, history: history}
  end

  defp maybe_reset_rate_limit(state) do
    now = System.system_time(:second)

    if now - state.hour_start >= 3600 do
      %{state | actions_this_hour: 0, hour_start: now}
    else
      state
    end
  end

  defp audit_log(result, disposition) do
    line =
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} " <>
        "action=#{result.action} confidence=#{result.confidence} " <>
        "disposition=#{disposition} reason=#{result.reason}\n"

    File.write(@audit_log_path, line, [:append])
  rescue
    _ -> :ok
  end
end
