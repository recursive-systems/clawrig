defmodule Clawrig.Updater do
  @moduledoc """
  OTA updater GenServer.

  Checks GitHub Releases on a 30-minute timer for the latest release,
  verifies checksums and signatures, and performs atomic swap upgrades
  with rollback on health-check failure.

  Auto-updates are enabled by default and can be toggled via the
  dashboard. Manual checks via `check_now/0` always work regardless
  of the auto-update setting.
  """

  use GenServer
  require Logger

  alias Clawrig.System.Commands
  alias Clawrig.OpenAI.Credentials, as: OpenAICredentials
  alias Clawrig.Auth.CodexAuth
  alias Clawrig.Wizard.State

  @check_interval :timer.hours(24)
  @install_dir "/opt/clawrig"
  @staging_dir "/opt/clawrig-staging"
  @prev_dir "/opt/clawrig-prev"
  @version_file "/opt/clawrig/VERSION"
  @pubkey_path "/etc/clawrig/update-pubkey"
  @token_path "/etc/clawrig/github-token"
  @pending_marker "/var/lib/clawrig/.update-pending"
  @repo "recursive-systems/clawrig"
  @api_base "https://api.github.com"

  @required_manifest_fields ~w(version tarball signature checksum released_at)
  @max_retry_attempts 2

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an update check now (GenServer.call). Always works regardless of auto-update setting."
  def check_now do
    GenServer.call(__MODULE__, :check_now, 60_000)
  end

  @doc "Alias for `check_now/0` (backward compat with dashboard_live)."
  def check, do: check_now()

  @doc "Parse a persisted pending-update marker for testability and diagnostics."
  def parse_pending_marker_public(marker), do: parse_pending_marker(marker)

  @doc "Classify upgrade risk for testability and diagnostics."
  def classify_update_risk_public(remote, local), do: classify_update_risk(remote, local)

  @doc "Run the post-update auth probe for testability and diagnostics."
  def post_update_auth_probe_public(version), do: post_update_auth_probe(version)

  @doc "Resolve reconciliation outcome for testability and diagnostics."
  def reconcile_outcome_public(mode, service_active?, auth_probe_result) do
    reconcile_outcome(mode, service_active?, auth_probe_result)
  end

  @doc "Simulate boot-time reconciliation side effects for testability."
  def simulate_reconcile_public(mode, version, service_active?, auth_probe_result) do
    case reconcile_outcome(mode, service_active?, auth_probe_result) do
      :updated ->
        %{status: :updated, version: version, rollback: false, resume_reason: nil}

      :rolled_back_auth_required ->
        %{
          status: :rolled_back_auth_required,
          version: version,
          rollback: true,
          resume_reason: :rolled_back_auth_required
        }

      :pending_reauth_post_update ->
        %{
          status: :pending_reauth_post_update,
          version: version,
          rollback: false,
          resume_reason: :pending_reauth_post_update
        }

      :health_failed ->
        %{status: :health_failed, version: version, rollback: true, resume_reason: nil}
    end
  end

  @doc "Returns the maximum number of guided retry attempts before manual investigation is required."
  def max_retry_attempts, do: @max_retry_attempts

  @doc "Returns whether a retry is still allowed for the given persisted attempt count."
  def retry_allowed_public?(attempts), do: retry_allowed?(attempts)

  @doc "Enable or disable automatic update checks."
  def set_auto_update(enabled) when is_boolean(enabled) do
    GenServer.call(__MODULE__, {:set_auto_update, enabled})
  end

  @doc "Returns true if automatic updates are enabled (default: true)."
  def auto_update_enabled? do
    Clawrig.Wizard.State.get(:auto_update_enabled) != false
  end

  @doc """
  Parses and validates a manifest map from a GitHub release asset.

  Returns `{:ok, parsed}` with atom keys or `{:error, reason}`.
  """
  def parse_manifest(manifest) when is_map(manifest) do
    missing =
      @required_manifest_fields
      |> Enum.reject(&Map.has_key?(manifest, &1))

    if missing == [] do
      parsed = %{
        version: manifest["version"],
        tarball: manifest["tarball"],
        signature: manifest["signature"],
        checksum: manifest["checksum"],
        released_at: manifest["released_at"]
      }

      {:ok, parsed}
    else
      {:error, "manifest missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  def parse_manifest(_), do: {:error, "manifest must be a map"}

  @doc """
  Returns `true` if `remote` is a strictly newer semver than `local`.
  """
  def version_newer?(remote, local) when is_binary(remote) and is_binary(local) do
    with {:ok, remote_v} <- Version.parse(remote),
         {:ok, local_v} <- Version.parse(local) do
      Version.compare(remote_v, local_v) == :gt
    else
      _ -> false
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{last_check: nil, last_result: nil}

    # Boot-time reconciliation: check if an update was in progress when we restarted
    reconcile_pending_update()

    if oobe_complete?() and auto_update_enabled?() do
      schedule_check()
      Logger.info("[Updater] Scheduled daily update checks")
    else
      reason = if !oobe_complete?(), do: "OOBE not complete", else: "auto-updates disabled"
      Logger.info("[Updater] #{reason} — update checks disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    result = do_check_and_update(:manual)
    new_state = %{state | last_check: DateTime.utc_now(), last_result: result}
    {:reply, result, new_state}
  end

  def handle_call({:set_auto_update, enabled}, _from, state) do
    Clawrig.Wizard.State.put(:auto_update_enabled, enabled)

    if enabled do
      schedule_check()
      Logger.info("[Updater] Auto-updates enabled, scheduling checks")
    else
      Logger.info("[Updater] Auto-updates disabled")
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    if auto_update_enabled?() do
      result = do_check_and_update(:auto)
      schedule_check()
      new_state = %{state | last_check: DateTime.utc_now(), last_result: result}
      {:noreply, new_state}
    else
      Logger.info("[Updater] Auto-updates disabled, skipping scheduled check")
      {:noreply, state}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp schedule_check do
    Process.send_after(self(), :scheduled_check, @check_interval)
  end

  defp oobe_complete? do
    File.exists?(Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete"))
  end

  defp broadcast(status) do
    record_update_event(status)
    Phoenix.PubSub.broadcast(Clawrig.PubSub, "clawrig:updates", {:update_status, status})
  end

  # ── Boot-time reconciliation ────────────────────────────────────────

  defp reconcile_pending_update do
    case File.read(@pending_marker) do
      {:ok, marker} ->
        %{version: version, mode: mode} = parse_pending_marker(marker)
        Logger.info("[Updater] Found pending update marker for v#{version}, running health check")

        # Give the service a moment to stabilize after restart
        Process.sleep(5_000)

        service_active? =
          case System.cmd("sudo", ["systemctl", "is-active", "clawrig"], stderr_to_stdout: true) do
            {"active\n", 0} -> true
            _ -> false
          end

        auth_probe_result =
          if service_active?,
            do: post_update_auth_probe(version),
            else: {:error, :service_unhealthy}

        case reconcile_outcome(mode, service_active?, auth_probe_result) do
          :updated ->
            Logger.info("[Updater] Post-update health check passed for v#{version}")
            File.rm(@pending_marker)
            sudo_rm_rf(@prev_dir)

            State.merge(%{
              update_resume_version: nil,
              update_resume_reason: nil,
              update_retry_attempts: 0
            })

            broadcast({:ok, :updated, version})

          :rolled_back_auth_required ->
            Logger.warning(
              "[Updater] Post-update auth probe requires re-auth for auto update v#{version}; rolling back"
            )

            rollback()
            File.rm(@pending_marker)

            State.merge(%{
              update_resume_version: version,
              update_resume_reason: :rolled_back_auth_required,
              update_retry_attempts: 0
            })

            broadcast({:ok, :rolled_back_auth_required, version})

          :pending_reauth_post_update ->
            Logger.warning(
              "[Updater] Post-update auth probe requires re-auth for manual update v#{version}"
            )

            File.rm(@pending_marker)
            sudo_rm_rf(@prev_dir)

            State.merge(%{
              update_resume_version: version,
              update_resume_reason: :pending_reauth_post_update,
              update_retry_attempts: 0
            })

            broadcast({:ok, :pending_reauth_post_update, version})

          :health_failed ->
            Logger.error("[Updater] Post-update health check failed — rolling back")
            rollback()
            File.rm(@pending_marker)
            broadcast({:error, "health check failed after update to v#{version}, rolled back"})
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Updater] Could not read pending marker: #{inspect(reason)}")
    end
  end

  # ── Check & Update ─────────────────────────────────────────────────

  defp do_check_and_update(mode) do
    broadcast(:checking)

    with {:ok, manifest} <- fetch_manifest(),
         {:ok, parsed} <- parse_manifest(manifest),
         local_version <- read_local_version(),
         true <- version_newer?(parsed.version, local_version) do
      Logger.info("[Updater] New version #{parsed.version} available (local: #{local_version})")

      case maybe_defer_for_recovery_path(parsed.version, local_version) do
        :ok ->
          apply_update(parsed, mode)

        {:deferred, reason} ->
          broadcast({:ok, :pending_recovery_path, parsed.version, reason})
          {:ok, :pending_recovery_path, parsed.version}
      end
    else
      false ->
        Logger.debug("[Updater] Already up to date")
        broadcast({:ok, :up_to_date})
        {:ok, :up_to_date}

      {:error, reason} = err ->
        Logger.warning("[Updater] Check failed: #{inspect(reason)}")
        broadcast(err)
        err
    end
  end

  defp fetch_manifest do
    url = "#{@api_base}/repos/#{@repo}/releases/latest"
    headers = auth_headers()

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        find_manifest_in_assets(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitHub API returned #{status}"}

      {:error, reason} ->
        {:error, "GitHub API request failed: #{inspect(reason)}"}
    end
  end

  defp find_manifest_in_assets(%{"assets" => assets}) when is_list(assets) do
    manifest_asset =
      Enum.find(assets, fn a -> a["name"] == "manifest.json" end)

    case manifest_asset do
      nil ->
        {:error, "no manifest.json in release assets"}

      %{"browser_download_url" => url} ->
        case Req.get(url, headers: auth_headers()) do
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
            {:ok, body}

          {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
            Jason.decode(body)

          {:ok, %Req.Response{status: status}} ->
            {:error, "manifest download returned #{status}"}

          {:error, reason} ->
            {:error, "manifest download failed: #{inspect(reason)}"}
        end
    end
  end

  defp find_manifest_in_assets(_), do: {:error, "release has no assets"}

  defp apply_update(parsed, mode) do
    broadcast({:ok, :downloading, parsed.version})

    with :ok <- download_tarball(parsed),
         :ok <- verify_checksum(parsed),
         :ok <- verify_signature(parsed),
         :ok <- extract_staging() do
      broadcast({:ok, :installing, parsed.version})

      case swap_and_restart(parsed.version, mode) do
        :ok ->
          # The process will be killed by systemctl restart.
          # Boot-time reconciliation in init/1 handles the health check.
          Logger.info("[Updater] Update to #{parsed.version} applied, restarting service")
          {:ok, :updated}

        {:error, _} = err ->
          err
      end
    else
      {:error, reason} = err ->
        Logger.error("[Updater] Update failed: #{inspect(reason)}")
        broadcast(err)
        cleanup_staging()
        err
    end
  end

  defp download_tarball(parsed) do
    url = "#{@api_base}/repos/#{@repo}/releases/latest"
    headers = auth_headers()

    with {:ok, %Req.Response{status: 200, body: release}} <- Req.get(url, headers: headers) do
      asset =
        (release["assets"] || [])
        |> Enum.find(fn a -> a["name"] == parsed.tarball end)

      case asset do
        nil ->
          {:error, "tarball asset #{parsed.tarball} not found"}

        %{"browser_download_url" => dl_url} ->
          sudo_mkdir_p(@staging_dir)
          sudo_chown(@staging_dir)
          dest = Path.join(@staging_dir, parsed.tarball)

          case Req.get(dl_url, headers: auth_headers(), into: File.stream!(dest)) do
            {:ok, %Req.Response{status: 200}} -> :ok
            {:ok, %Req.Response{status: s}} -> {:error, "tarball download returned #{s}"}
            {:error, reason} -> {:error, "tarball download failed: #{inspect(reason)}"}
          end
      end
    end
  end

  defp verify_checksum(parsed) do
    tarball_path = Path.join(@staging_dir, parsed.tarball)

    case File.read(tarball_path) do
      {:ok, data} ->
        actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

        if actual == String.downcase(parsed.checksum) do
          :ok
        else
          {:error, "checksum mismatch: expected #{parsed.checksum}, got #{actual}"}
        end

      {:error, reason} ->
        {:error, "cannot read tarball for checksum: #{inspect(reason)}"}
    end
  end

  defp verify_signature(parsed) do
    case File.read(@pubkey_path) do
      {:ok, pubkey_pem} ->
        tarball_path = Path.join(@staging_dir, parsed.tarball)

        with {:ok, data} <- File.read(tarball_path),
             {:ok, sig_bytes} <- Base.decode64(parsed.signature) do
          [entry] = :public_key.pem_decode(pubkey_pem)
          pubkey = :public_key.pem_entry_decode(entry)

          if :public_key.verify(data, :none, sig_bytes, pubkey) do
            :ok
          else
            {:error, "signature verification failed"}
          end
        else
          :error -> {:error, "invalid base64 signature"}
          {:error, reason} -> {:error, "signature check failed: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        Logger.warning("[Updater] No pubkey at #{@pubkey_path} — skipping signature verification")
        :ok

      {:error, reason} ->
        {:error, "cannot read pubkey: #{inspect(reason)}"}
    end
  end

  defp extract_staging do
    tarball =
      case File.ls(@staging_dir) do
        {:ok, files} -> Enum.find(files, &String.ends_with?(&1, ".tar.gz"))
        _ -> nil
      end

    if tarball do
      tarball_path = Path.join(@staging_dir, tarball)

      case System.cmd("tar", ["-xzf", tarball_path, "-C", @staging_dir, "--strip-components=1"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, "tar extraction failed: #{output}"}
      end
    else
      {:error, "no tarball found in staging directory"}
    end
  end

  defp swap_and_restart(version, mode) do
    try do
      # Remove previous backup
      if File.exists?(@prev_dir), do: sudo_rm_rf(@prev_dir)

      # Move current install to backup
      if File.exists?(@install_dir) do
        sudo_mv(@install_dir, @prev_dir)
      end

      # Move staging to install
      sudo_mv(@staging_dir, @install_dir)
      sudo_chown(@install_dir)

      # Write pending marker so boot-time reconciliation can run the health + auth checks
      File.write!(@pending_marker, Jason.encode!(%{version: version, mode: Atom.to_string(mode)}))

      # Restart the service — this will kill our process.
      # The new instance's init/1 handles health check via reconcile_pending_update/0.
      System.cmd("sudo", ["systemctl", "restart", "clawrig"], stderr_to_stdout: true)
      :ok
    rescue
      e ->
        Logger.error("[Updater] Swap failed: #{Exception.message(e)} — rolling back")
        rollback()
        {:error, "swap failed: #{Exception.message(e)}"}
    end
  end

  defp rollback do
    try do
      if File.exists?(@prev_dir) do
        if File.exists?(@install_dir), do: sudo_rm_rf(@install_dir)
        sudo_mv(@prev_dir, @install_dir)
        System.cmd("sudo", ["systemctl", "restart", "clawrig"], stderr_to_stdout: true)
      end
    rescue
      e -> Logger.error("[Updater] Rollback failed: #{Exception.message(e)}")
    end
  end

  defp cleanup_staging do
    if File.exists?(@staging_dir), do: sudo_rm_rf(@staging_dir)
  end

  # ── Sudo helpers ───────────────────────────────────────────────────

  defp sudo_mkdir_p(path) do
    System.cmd("sudo", ["mkdir", "-p", path], stderr_to_stdout: true)
  end

  defp sudo_mv(src, dest) do
    {_, 0} = System.cmd("sudo", ["mv", src, dest], stderr_to_stdout: true)
  end

  defp sudo_rm_rf(path) do
    System.cmd("sudo", ["rm", "-rf", path], stderr_to_stdout: true)
  end

  defp sudo_chown(path) do
    System.cmd("sudo", ["chown", "-R", "pi:pi", path], stderr_to_stdout: true)
  end

  # ── Version & Auth ─────────────────────────────────────────────────

  defp read_local_version do
    case File.read(@version_file) do
      {:ok, content} -> String.trim(content)
      _ -> "0.0.0"
    end
  end

  defp read_token do
    case File.read(@token_path) do
      {:ok, token} -> String.trim(token)
      _ -> nil
    end
  end

  defp auth_headers do
    case read_token() do
      nil -> [{"accept", "application/vnd.github+json"}]
      token -> [{"accept", "application/vnd.github+json"}, {"authorization", "Bearer #{token}"}]
    end
  end

  defp parse_pending_marker(marker) do
    case Jason.decode(marker) do
      {:ok, %{"version" => version, "mode" => mode}} ->
        %{version: version, mode: parse_update_mode(mode)}

      _ ->
        %{version: String.trim(marker), mode: :auto}
    end
  end

  defp parse_update_mode("manual"), do: :manual
  defp parse_update_mode(_), do: :auto

  defp post_update_auth_probe(_version) do
    cond do
      not using_openai_codex?() ->
        :ok

      not OpenAICredentials.auth_configured?() ->
        {:error, :reauth_required}

      not CodexAuth.auth_exists?() ->
        {:error, :reauth_required}

      true ->
        case Commands.impl().run_openclaw(["models", "status"]) do
          {output, 0} ->
            lowered = String.downcase(output || "")

            if String.contains?(lowered, "unauthorized") or String.contains?(lowered, "expired") or
                 String.contains?(lowered, "re-auth") or String.contains?(lowered, "reauth") do
              {:error, :reauth_required}
            else
              :ok
            end

          _ ->
            {:error, :reauth_required}
        end
    end
  rescue
    _ -> {:error, :reauth_required}
  end

  defp using_openai_codex? do
    case Commands.impl().run_openclaw(["config", "get", "agents.defaults.model.primary"]) do
      {output, 0} -> String.contains?(output || "", "openai-codex/")
      _ -> true
    end
  end

  defp reconcile_outcome(_mode, false, _auth_probe_result), do: :health_failed
  defp reconcile_outcome(_mode, true, :ok), do: :updated
  defp reconcile_outcome(:auto, true, {:error, :reauth_required}), do: :rolled_back_auth_required

  defp reconcile_outcome(:manual, true, {:error, :reauth_required}),
    do: :pending_reauth_post_update

  defp reconcile_outcome(_mode, true, _), do: :health_failed

  defp retry_allowed?(attempts) when is_integer(attempts), do: attempts < @max_retry_attempts
  defp retry_allowed?(_), do: false

  defp record_update_event(status) do
    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "status" => render_update_status(status)
    }

    history =
      State.get(:update_history)
      |> case do
        history when is_list(history) -> history
        _ -> []
      end

    State.put(:update_history, [entry | history] |> Enum.take(12))
  rescue
    _ -> :ok
  end

  defp render_update_status(:checking), do: "checking"
  defp render_update_status({:ok, state}), do: Atom.to_string(state)
  defp render_update_status({:ok, state, version}), do: "#{Atom.to_string(state)}:#{version}"

  defp render_update_status({:ok, state, version, _reason}),
    do: "#{Atom.to_string(state)}:#{version}"

  defp render_update_status({:error, reason}), do: "error:#{reason}"
  defp render_update_status(other), do: inspect(other)

  defp maybe_defer_for_recovery_path(remote_version, local_version) do
    case classify_update_risk(remote_version, local_version) do
      :safe ->
        :ok

      risk when risk in [:guarded, :breaking] ->
        if recovery_path_available?() do
          :ok
        else
          {:deferred,
           "Update risk=#{risk}. Recovery path unavailable (need local network presence or healthy Tailscale)."}
        end
    end
  end

  defp classify_update_risk(remote, local) do
    with {:ok, rv} <- Version.parse(remote),
         {:ok, lv} <- Version.parse(local) do
      cond do
        rv.major > lv.major -> :breaking
        rv.minor > lv.minor -> :guarded
        true -> :safe
      end
    else
      _ -> :guarded
    end
  end

  defp recovery_path_available? do
    tailscale_ok =
      case Commands.impl().tailscale_status() do
        %{running: true, ip: ip} when is_binary(ip) and ip != "" -> true
        %{running: true} -> true
        _ -> false
      end

    local_ok =
      case Commands.impl().detect_local_ip() do
        ip when is_binary(ip) and ip != "" -> true
        _ -> false
      end

    tailscale_ok or local_ok
  rescue
    _ -> false
  end
end
