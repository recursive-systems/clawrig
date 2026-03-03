defmodule ClawrigWeb.DashboardLive do
  use ClawrigWeb, :live_view

  alias Clawrig.System.Commands
  alias Clawrig.Wizard.State

  @refresh_interval 10_000
  @openai_poll_timeout_count 180

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Kick off an async status check instead of blocking mount.
      send(self(), :refresh_status)
    end

    socket =
      socket
      |> assign(:gateway_status, :loading)
      |> assign(:internet, :loading)
      |> assign(:wifi_ssid, :loading)
      |> assign(:version, read_version())
      |> assign(:openai_status, :loading)
      |> assign(:logs, nil)
      |> assign(:update_status, nil)
      |> assign(:account_sub, :idle)
      |> assign(:account_error, nil)
      |> assign(:openai_user_code, nil)
      |> assign(:openai_device_auth_id, nil)
      |> assign(:openai_poll_interval, 5)
      |> assign(:openai_polling, false)
      |> assign(:openai_poll_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ---------- Events ----------

  @impl true
  def handle_event("restart_gateway", _params, socket) do
    Task.start(fn ->
      Commands.impl().start_gateway()
    end)

    {:noreply, put_flash(socket, :info, "Restarting gateway...")}
  end

  def handle_event("run_repair", _params, socket) do
    Task.start(fn ->
      Commands.impl().run_openclaw(["doctor", "--fix"])
    end)

    {:noreply, put_flash(socket, :info, "Running repair...")}
  end

  def handle_event("reboot", _params, socket) do
    Task.start(fn ->
      Process.sleep(2000)

      try do
        System.cmd("reboot", [])
      rescue
        _ -> :ok
      end
    end)

    {:noreply, put_flash(socket, :info, "Rebooting in 2 seconds...")}
  end

  def handle_event("check_update", _params, socket) do
    send(self(), :check_update)
    {:noreply, assign(socket, :update_status, :checking)}
  end

  def handle_event("view_logs", _params, socket) do
    {:noreply, assign(socket, :logs, read_logs())}
  end

  # ---------- Account events ----------

  def handle_event("disconnect_openai", _params, socket) do
    State.merge(%{
      openai_done: false,
      openai_auth_method: nil,
      openai_device_auth_id: nil,
      openai_user_code: nil
    })

    {:noreply,
     socket
     |> assign(:openai_status, :disconnected)
     |> assign(:account_sub, :choose)
     |> assign(:account_error, nil)
     |> put_flash(:info, "OpenAI account disconnected.")}
  end

  def handle_event("account_start_device_code", _params, socket) do
    send(self(), :account_request_user_code)
    {:noreply, assign(socket, account_sub: :device_code, account_error: nil)}
  end

  def handle_event("account_use_api_key", _params, socket) do
    {:noreply, assign(socket, account_sub: :api_key, account_error: nil)}
  end

  def handle_event("account_back_to_choose", _params, socket) do
    State.merge(%{openai_device_auth_id: nil, openai_user_code: nil})

    {:noreply,
     assign(socket,
       account_sub: :choose,
       account_error: nil,
       openai_polling: false,
       openai_user_code: nil,
       openai_device_auth_id: nil,
       openai_poll_count: 0
     )}
  end

  def handle_event("account_submit_api_key", %{"api_key" => key}, socket) do
    key = String.trim(key)

    if key == "" do
      {:noreply, assign(socket, :account_error, "Please paste your API key.")}
    else
      send(self(), {:account_save_api_key, key, :api_key})
      {:noreply, assign(socket, account_sub: :saving, account_error: nil)}
    end
  end

  def handle_event("page_visible", _params, socket) do
    if socket.assigns.openai_polling and socket.assigns.account_sub == :device_code do
      send(self(), :account_poll)
    end

    {:noreply, socket}
  end

  # ---------- Info ----------

  @impl true
  def handle_info(:refresh_status, socket) do
    Process.send_after(self(), :refresh_status, @refresh_interval)

    # Run status checks in a separate process so the LiveView stays responsive
    # (gateway_status can take 10+ seconds due to RPC probe timeout).
    pid = self()

    Task.start(fn ->
      gateway = Commands.impl().gateway_status()
      internet = Commands.impl().check_internet()

      wifi_ssid =
        try do
          {result, 0} = System.cmd("nmcli", ["-t", "-f", "ACTIVE,SSID", "dev", "wifi"])

          result
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ":", parts: 2) do
              ["yes", ssid] -> ssid
              _ -> nil
            end
          end)
        rescue
          _ -> nil
        end

      send(pid, {:status_result, gateway, internet, wifi_ssid})
    end)

    {:noreply, socket}
  end

  def handle_info({:status_result, gateway, internet, wifi_ssid}, socket) do
    openai_status =
      if State.get(:openai_done), do: :connected, else: :disconnected

    account_sub =
      cond do
        socket.assigns.account_sub != :idle -> socket.assigns.account_sub
        openai_status == :connected -> :idle
        true -> :choose
      end

    {:noreply,
     socket
     |> assign(:gateway_status, gateway)
     |> assign(:internet, internet)
     |> assign(:wifi_ssid, wifi_ssid)
     |> assign(:openai_status, openai_status)
     |> assign(:account_sub, account_sub)}
  end

  def handle_info(:check_update, socket) do
    status =
      try do
        Clawrig.Updater.check()
      rescue
        _ -> {:error, "Updater not available"}
      catch
        :exit, _ -> {:error, "Updater not available"}
      end

    {:noreply, assign(socket, :update_status, status)}
  end

  def handle_info({ClawrigWeb.WifiComponent, {:wifi_connected, ssid}}, socket) do
    {:noreply, assign(socket, :wifi_ssid, ssid)}
  end

  # ---------- Account info ----------

  def handle_info(:account_request_user_code, socket) do
    case device_code_impl().request_user_code() do
      {:ok, %{device_auth_id: id, user_code: code, interval: interval}} ->
        State.merge(%{openai_device_auth_id: id, openai_user_code: code})
        Process.send_after(self(), :account_poll, interval * 1000)

        {:noreply,
         assign(socket,
           account_sub: :device_code,
           openai_user_code: code,
           openai_device_auth_id: id,
           openai_poll_interval: interval,
           openai_polling: true,
           openai_poll_count: 0
         )}

      {:error, :not_enabled} ->
        {:noreply,
         assign(socket,
           account_sub: :error,
           account_error:
             "Device code authorization isn't enabled on your OpenAI account. " <>
               "Enable it in ChatGPT Settings > Security > \"Device code authorization for Codex\", then try again."
         )}

      {:error, msg} ->
        {:noreply, assign(socket, account_sub: :error, account_error: "#{msg}")}
    end
  end

  def handle_info(:account_poll, socket) do
    if !socket.assigns.openai_polling || socket.assigns.account_sub != :device_code do
      {:noreply, assign(socket, openai_polling: false)}
    else
      if socket.assigns.openai_poll_count >= @openai_poll_timeout_count do
        {:noreply,
         assign(socket,
           account_sub: :error,
           openai_polling: false,
           account_error: "Authorization timed out. Please try again."
         )}
      else
        case device_code_impl().poll_authorization(
               socket.assigns.openai_device_auth_id,
               socket.assigns.openai_user_code
             ) do
          :pending ->
            Process.send_after(self(), :account_poll, socket.assigns.openai_poll_interval * 1000)
            {:noreply, assign(socket, openai_poll_count: socket.assigns.openai_poll_count + 1)}

          {:ok, auth_data} ->
            send(self(), {:account_exchange_tokens, auth_data})
            {:noreply, assign(socket, openai_polling: false)}

          {:error, msg} ->
            {:noreply,
             assign(socket,
               account_sub: :error,
               openai_polling: false,
               account_error: "#{msg}"
             )}
        end
      end
    end
  end

  def handle_info({:account_exchange_tokens, auth_data}, socket) do
    case device_code_impl().complete_flow(auth_data) do
      {:ok, oauth_creds} ->
        send(self(), {:account_save_oauth_creds, oauth_creds})
        {:noreply, assign(socket, account_sub: :saving)}

      {:error, msg} ->
        {:noreply, assign(socket, account_sub: :error, account_error: "#{msg}")}
    end
  end

  # Device code flow: write OAuth credentials directly to OpenClaw's auth store
  def handle_info({:account_save_oauth_creds, oauth_creds}, socket) do
    pid = self()

    Task.start(fn ->
      result = write_oauth_credentials(oauth_creds)
      send(pid, {:account_save_result, result, :device_code})
    end)

    {:noreply, assign(socket, account_sub: :saving, account_error: nil)}
  end

  # API key paste flow: run openclaw onboard
  def handle_info({:account_save_api_key, key, method}, socket) do
    pid = self()

    Task.start(fn ->
      {output, exit_code} =
        Commands.impl().run_openclaw([
          "onboard",
          "--non-interactive",
          "--accept-risk",
          "--auth-choice",
          "openai-api-key",
          "--openai-api-key",
          key,
          "--skip-channels",
          "--skip-health",
          "--skip-skills",
          "--skip-daemon",
          "--skip-ui"
        ])

      result = if exit_code == 0, do: :ok, else: {:error, String.trim(output)}
      send(pid, {:account_save_result, result, method})
    end)

    {:noreply, assign(socket, account_sub: :saving, account_error: nil)}
  end

  def handle_info({:account_save_result, :ok, method}, socket) do
    method_str = if method == :api_key, do: "api-key", else: "device-code"

    State.merge(%{
      openai_done: true,
      openai_auth_method: method_str,
      openai_device_auth_id: nil,
      openai_user_code: nil
    })

    Task.start(fn -> Commands.impl().start_gateway() end)

    {:noreply,
     socket
     |> assign(
       openai_status: :connected,
       account_sub: :idle,
       account_error: nil,
       openai_user_code: nil,
       openai_device_auth_id: nil
     )
     |> put_flash(:info, "OpenAI account connected. Gateway restarting...")}
  end

  def handle_info({:account_save_result, {:error, msg}, _method}, socket) do
    {:noreply,
     assign(socket,
       account_sub: :error,
       account_error: "Could not save credentials. #{msg}"
     )}
  end

  # ---------- Private ----------

  @auth_profiles_path "/home/pi/.openclaw/agents/main/agent/auth-profiles.json"

  defp write_oauth_credentials(oauth_creds) do
    profile_id =
      if is_binary(oauth_creds.email) and oauth_creds.email != "",
        do: "openai-codex:#{oauth_creds.email}",
        else: "openai-codex:default"

    credential = %{
      "type" => "oauth",
      "provider" => "openai-codex",
      "access" => oauth_creds.access,
      "refresh" => oauth_creds.refresh,
      "expires" => oauth_creds.expires,
      "email" => oauth_creds.email
    }

    # Read existing auth-profiles.json, upsert the profile, write back
    store =
      case File.read(@auth_profiles_path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{"version" => 1, "profiles" => %{}}
      end

    store = put_in(store, ["profiles", profile_id], credential)

    case File.write(@auth_profiles_path, Jason.encode!(store, pretty: true)) do
      :ok ->
        # Set openclaw.json config: auth profile + model for openai-codex
        Commands.impl().run_openclaw([
          "config",
          "set",
          "auth.profiles.#{profile_id}",
          Jason.encode!(%{provider: "openai-codex", mode: "oauth"}),
          "--strict-json"
        ])

        Commands.impl().run_openclaw([
          "config",
          "set",
          "agents.defaults.model.primary",
          "openai-codex/gpt-5.3-codex"
        ])

        :ok

      {:error, reason} ->
        {:error, "Failed to write auth-profiles.json: #{inspect(reason)}"}
    end
  end

  defp device_code_impl do
    Application.get_env(:clawrig, :device_code_module, Clawrig.Wizard.DeviceCode)
  end

  defp read_version do
    case File.read("/opt/clawrig/VERSION") do
      {:ok, content} -> String.trim(content)
      _ -> "dev"
    end
  end

  defp read_logs do
    repair_log =
      case File.read("/var/log/clawrig-repair.log") do
        {:ok, content} -> content
        _ -> ""
      end

    gateway_log =
      try do
        {output, 0} =
          System.cmd("journalctl", ["-u", "openclaw-gateway", "-n", "50", "--no-pager"])

        output
      rescue
        _ -> ""
      end

    String.trim("--- Repair Log ---\n#{repair_log}\n\n--- Gateway Log ---\n#{gateway_log}")
  end

  # ---------- View helpers ----------

  def status_color(:loading), do: "loading"
  def status_color(:running), do: "ok"
  def status_color(true), do: "ok"
  def status_color(:connected), do: "ok"
  def status_color(:stopped), do: "err"
  def status_color(false), do: "err"
  def status_color(:disconnected), do: "warn"
  def status_color(_), do: ""

  def status_label(:loading), do: "Checking..."
  def status_label(:running), do: "Running"
  def status_label(:stopped), do: "Stopped"
  def status_label(true), do: "Online"
  def status_label(false), do: "Offline"
  def status_label(:connected), do: "Connected"
  def status_label(:disconnected), do: "Not connected"
  def status_label(:waiting), do: "Waiting..."
  def status_label(:checking), do: "Checking..."
  def status_label(:unknown), do: "Unknown"
  def status_label(nil), do: "N/A"
  def status_label(other) when is_binary(other), do: other
  def status_label(_), do: "Unknown"

  def tab_class(live_action, tab) when live_action == tab, do: "dash-tab active"
  def tab_class(_live_action, _tab), do: "dash-tab"
end
