defmodule Clawrig.Updater do
  @moduledoc """
  OTA updater GenServer.

  Checks GitHub Releases on a 30-minute timer for the latest release,
  verifies checksums and signatures, and performs atomic swap upgrades
  with rollback on health-check failure.
  """

  use GenServer
  require Logger

  @check_interval :timer.minutes(30)
  @install_dir "/opt/clawrig"
  @staging_dir "/opt/clawrig-staging"
  @prev_dir "/opt/clawrig-prev"
  @version_file "/opt/clawrig/VERSION"
  @pubkey_path "/etc/clawrig/update-pubkey"
  @token_path "/etc/clawrig/github-token"
  @repo "recursive-systems/openclaw_monorepo"
  @api_base "https://api.github.com"

  @required_manifest_fields ~w(version tarball signature checksum released_at)

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an update check now (GenServer.call)."
  def check_now do
    GenServer.call(__MODULE__, :check_now, 60_000)
  end

  @doc "Alias for `check_now/0` (backward compat with dashboard_live)."
  def check, do: check_now()

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
    if oobe_complete?() do
      schedule_check()
      Logger.info("[Updater] Scheduled update checks every #{div(@check_interval, 60_000)}m")
    else
      Logger.info("[Updater] OOBE not complete — update checks disabled")
    end

    {:ok, %{last_check: nil, last_result: nil}}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    result = do_check_and_update()

    new_state = %{state | last_check: DateTime.utc_now(), last_result: result}
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    result = do_check_and_update()
    schedule_check()

    new_state = %{state | last_check: DateTime.utc_now(), last_result: result}
    {:noreply, new_state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp schedule_check do
    Process.send_after(self(), :scheduled_check, @check_interval)
  end

  defp oobe_complete? do
    File.exists?(Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete"))
  end

  defp do_check_and_update do
    with {:ok, manifest} <- fetch_manifest(),
         {:ok, parsed} <- parse_manifest(manifest),
         local_version <- read_local_version(),
         true <- version_newer?(parsed.version, local_version) do
      Logger.info("[Updater] New version #{parsed.version} available (local: #{local_version})")
      apply_update(parsed)
    else
      false ->
        Logger.debug("[Updater] Already up to date")
        {:ok, :up_to_date}

      {:error, reason} = err ->
        Logger.warning("[Updater] Check failed: #{inspect(reason)}")
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

  defp apply_update(parsed) do
    with :ok <- download_tarball(parsed),
         :ok <- verify_checksum(parsed),
         :ok <- verify_signature(parsed),
         :ok <- extract_staging(),
         :ok <- swap_and_restart() do
      Logger.info("[Updater] Update to #{parsed.version} completed successfully")
      {:ok, :updated}
    else
      {:error, reason} = err ->
        Logger.error("[Updater] Update failed: #{inspect(reason)}")
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
          File.mkdir_p!(@staging_dir)
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

      case System.cmd("tar", ["-xzf", tarball_path, "-C", @staging_dir],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, "tar extraction failed: #{output}"}
      end
    else
      {:error, "no tarball found in staging directory"}
    end
  end

  defp swap_and_restart do
    try do
      # Remove previous backup
      if File.exists?(@prev_dir), do: File.rm_rf!(@prev_dir)

      # Move current install to backup
      if File.exists?(@install_dir) do
        File.rename!(@install_dir, @prev_dir)
      end

      # Move staging to install
      File.rename!(@staging_dir, @install_dir)

      # Restart the service
      case System.cmd("systemctl", ["restart", "clawrig"], stderr_to_stdout: true) do
        {_, 0} ->
          # Brief health check
          Process.sleep(5_000)

          case System.cmd("systemctl", ["is-active", "clawrig"], stderr_to_stdout: true) do
            {"active\n", 0} ->
              :ok

            _ ->
              Logger.error("[Updater] Health check failed — rolling back")
              rollback()
              {:error, "health check failed after update, rolled back"}
          end

        {output, _} ->
          Logger.error("[Updater] Service restart failed — rolling back")
          rollback()
          {:error, "service restart failed: #{output}"}
      end
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
        if File.exists?(@install_dir), do: File.rm_rf!(@install_dir)
        File.rename!(@prev_dir, @install_dir)
        System.cmd("systemctl", ["restart", "clawrig"], stderr_to_stdout: true)
      end
    rescue
      e -> Logger.error("[Updater] Rollback failed: #{Exception.message(e)}")
    end
  end

  defp cleanup_staging do
    if File.exists?(@staging_dir) do
      File.rm_rf(@staging_dir)
    end
  end

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
end
