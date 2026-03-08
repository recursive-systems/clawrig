defmodule ClawrigWeb.DashboardLive do
  use ClawrigWeb, :live_view

  alias Clawrig.Integrations.Config, as: IntegrationsConfig
  alias Clawrig.Integrations.SearchProxy
  alias Clawrig.PreviewState
  alias Clawrig.System.Commands
  alias Clawrig.Wizard.State
  alias Clawrig.DashboardAuth

  @refresh_interval 10_000
  @openai_poll_timeout_count 180

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Clawrig.PubSub, "clawrig:updates")
      Phoenix.PubSub.subscribe(Clawrig.PubSub, "clawrig:node")
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
      |> assign(:update_version, nil)
      |> assign(:auto_update_enabled, Clawrig.Updater.auto_update_enabled?())
      |> assign(:account_sub, :idle)
      |> assign(:account_error, nil)
      |> assign(:account_provider_type, State.get(:provider_type))
      |> assign(:openai_user_code, nil)
      |> assign(:openai_device_auth_id, nil)
      |> assign(:openai_poll_interval, 5)
      |> assign(:openai_polling, false)
      |> assign(:openai_poll_count, 0)
      |> assign(:ethernet_connected, false)
      |> assign(:node_status, Clawrig.Node.Client.status())
      |> assign(:node_detail, Clawrig.Node.Client.status_detail())
      |> assign(:node_device_id, Clawrig.Node.Client.device_id())
      |> assign(:local_ip, State.get(:local_ip))
      |> assign(:brave_mode, IntegrationsConfig.search_mode())
      |> assign(:brave_error, nil)
      |> assign(:brave_usage, nil)
      |> assign(:brave_registering, false)
      |> assign(:tailscale, :loading)
      |> assign(:tailscale_error, nil)
      |> assign(:tailscale_connecting, false)
      |> assign(:tailscale_installing, false)
      |> assign(:tailscale_dev_override, nil)
      |> assign(:dev_tailscale_bypass_enabled, dev_tailscale_bypass_enabled?())
      |> assign(:preview_scenario, nil)
      |> assign(:autoheal, %{"enabled" => true, "health" => "unknown", "last_run_at" => nil, "last_result" => "unknown", "last_action" => nil, "last_check" => nil})
      |> assign(:autoheal_log, [])
      |> assign(:password_change_error, nil)
      |> assign(:password_change_ok, nil)
      |> assign(:password_change_strength, nil)
      |> assign(:password_current_value, "")
      |> assign(:password_new_value, "")
      |> assign(:password_new_confirm_value, "")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    preview_overrides = PreviewState.apply_dashboard(params)
    {:noreply, assign(socket, preview_overrides)}
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

  def handle_event("toggle_autoheal", _params, socket) do
    enabled = socket.assigns.autoheal["enabled"] != false

    case Commands.impl().autoheal_set_enabled(!enabled) do
      :ok ->
        msg = if enabled, do: "Auto-healing disabled.", else: "Auto-healing enabled."
        {:noreply, socket |> assign(:autoheal, Map.put(socket.assigns.autoheal, "enabled", !enabled)) |> put_flash(:info, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update auto-healing: #{reason}")}
    end
  end

  def handle_event("run_autoheal_now", _params, socket) do
    case Commands.impl().autoheal_run_now() do
      :ok ->
        {:noreply, put_flash(socket, :info, "Auto-heal run triggered.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Auto-heal run failed: #{reason}")}
    end
  end

  def handle_event("validate_change_dashboard_password", %{"current_password" => current, "new_password" => new_pw, "new_password_confirm" => confirm}, socket) do
    current = current || ""
    new_pw = new_pw || ""
    confirm = confirm || ""

    error =
      cond do
        confirm == "" -> nil
        new_pw != confirm -> "New passwords do not match"
        true -> nil
      end

    {:noreply,
     assign(socket,
       password_current_value: current,
       password_new_value: new_pw,
       password_new_confirm_value: confirm,
       password_change_error: error,
       password_change_ok: nil,
       password_change_strength: DashboardAuth.password_strength(new_pw)
     )}
  end

  def handle_event("change_dashboard_password", %{"current_password" => current, "new_password" => new_pw, "new_password_confirm" => confirm}, socket) do
    cond do
      String.trim(new_pw || "") == "" ->
        {:noreply,
         assign(socket,
           password_change_error: "New password is required",
           password_change_ok: nil,
           password_change_strength: nil,
           password_current_value: current || "",
           password_new_value: new_pw || "",
           password_new_confirm_value: confirm || ""
         )}

      new_pw != confirm ->
        {:noreply,
         assign(socket,
           password_change_error: "New passwords do not match",
           password_change_ok: nil,
           password_change_strength: DashboardAuth.password_strength(new_pw || ""),
           password_current_value: current || "",
           password_new_value: new_pw || "",
           password_new_confirm_value: confirm || ""
         )}

      true ->
        case DashboardAuth.change_password(current || "", new_pw) do
          :ok ->
            {:noreply,
             assign(socket,
               password_change_error: nil,
               password_change_ok: "Password updated",
               password_change_strength: nil,
               password_current_value: "",
               password_new_value: "",
               password_new_confirm_value: ""
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               password_change_error: reason,
               password_change_ok: nil,
               password_change_strength: DashboardAuth.password_strength(new_pw || ""),
               password_current_value: current || "",
               password_new_value: new_pw || "",
               password_new_confirm_value: confirm || ""
             )}
        end
    end
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

  def handle_event("tailscale_connect", %{"auth_key" => auth_key}, socket) do
    auth_key = String.trim(auth_key)

    if auth_key == "" do
      {:noreply, assign(socket, :tailscale_error, "Please enter an auth key.")}
    else
      if dev_tailscale_bypass_enabled?() and String.starts_with?(auth_key, "tskey-test-") do
        {:noreply,
         socket
         |> assign(
           tailscale: %{installed: true, running: true, ip: "100.64.0.99", hostname: "clawrig-dev"},
           tailscale_dev_override: %{installed: true, running: true, ip: "100.64.0.99", hostname: "clawrig-dev"},
           tailscale_error: nil,
           tailscale_connecting: false
         )
         |> put_flash(:info, "Dev mode: mock Tailscale connected")}
      else
        socket = assign(socket, tailscale_connecting: true, tailscale_error: nil)

        pid = self()

        Task.start(fn ->
          result = Commands.impl().tailscale_up(auth_key)
          send(pid, {:tailscale_result, result})
        end)

        {:noreply, socket}
      end
    end
  end

  def handle_event("tailscale_install", _params, socket) do
    socket = assign(socket, tailscale_installing: true, tailscale_error: nil)
    pid = self()

    Task.start(fn ->
      result = Commands.impl().tailscale_install()
      send(pid, {:tailscale_install_result, result})
    end)

    {:noreply, socket}
  end

  def handle_event("tailscale_mock_install", _params, socket) do
    if dev_tailscale_bypass_enabled?() do
      mock = %{installed: true, running: false, ip: nil, hostname: nil}

      {:noreply,
       socket
       |> assign(
         tailscale: mock,
         tailscale_dev_override: mock,
         tailscale_installing: false,
         tailscale_error: nil
       )
       |> put_flash(:info, "Dev mode: mock Tailscale installed")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("tailscale_disconnect", _params, socket) do
    if dev_tailscale_bypass_enabled?() and socket.assigns[:tailscale_dev_override] do
      disconnected = %{installed: true, running: false, ip: nil, hostname: nil}

      {:noreply,
       socket
       |> assign(tailscale: disconnected, tailscale_dev_override: disconnected, tailscale_error: nil)
       |> put_flash(:info, "Tailscale disconnected.")}
    else
      down_result = Commands.impl().tailscale_down()
      tailscale = Commands.impl().tailscale_status()

      # Treat disconnect as idempotent:
      # if Tailscale is already disconnected (including external key/session revocation),
      # we still surface success-like UX instead of a hard error.
      cond do
        tailscale.running == false ->
          {:noreply,
           socket
           |> assign(tailscale: tailscale, tailscale_error: nil)
           |> put_flash(:info, "Tailscale disconnected.")}

        down_result == :ok ->
          {:noreply,
           socket
           |> assign(tailscale: tailscale, tailscale_error: nil)
           |> put_flash(:info, "Tailscale disconnected.")}

        match?({:error, _}, down_result) ->
          {:error, reason} = down_result

          {:noreply,
           socket
           |> assign(tailscale: tailscale, tailscale_error: reason)
           |> put_flash(:error, "Could not disconnect Tailscale.")}
      end
    end
  end

  def handle_event("check_update", _params, socket) do
    send(self(), :check_update)
    {:noreply, assign(socket, :update_status, :checking)}
  end

  def handle_event("toggle_auto_update", _params, socket) do
    new_value = !socket.assigns.auto_update_enabled
    Clawrig.Updater.set_auto_update(new_value)
    {:noreply, assign(socket, :auto_update_enabled, new_value)}
  end

  def handle_event("view_logs", _params, socket) do
    {:noreply, assign(socket, :logs, read_logs())}
  end

  # ---------- Account events ----------

  def handle_event("disconnect_provider", _params, socket) do
    State.merge(%{
      provider_done: false,
      provider_type: nil,
      provider_auth_method: nil,
      provider_name: nil,
      provider_base_url: nil,
      provider_model_id: nil,
      openai_device_auth_id: nil,
      openai_user_code: nil
    })

    {:noreply,
     socket
     |> assign(:openai_status, :disconnected)
     |> assign(:account_sub, :choose_type)
     |> assign(:account_provider_type, nil)
     |> assign(:account_error, nil)
     |> put_flash(:info, "Provider disconnected.")}
  end

  def handle_event("account_choose_openai", _params, socket) do
    {:noreply, assign(socket, account_sub: :choose, account_provider_type: "openai")}
  end

  def handle_event("account_choose_compatible", _params, socket) do
    {:noreply,
     assign(socket, account_sub: :compat_form, account_provider_type: "openai-compatible")}
  end

  def handle_event("account_back_to_type", _params, socket) do
    State.merge(%{openai_device_auth_id: nil, openai_user_code: nil})

    {:noreply,
     assign(socket,
       account_sub: :choose_type,
       account_provider_type: nil,
       account_error: nil,
       openai_polling: false,
       openai_user_code: nil,
       openai_device_auth_id: nil,
       openai_poll_count: 0
     )}
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

  def handle_event("account_submit_compatible", params, socket) do
    base_url = String.trim(params["base_url"] || "")
    api_key = String.trim(params["api_key"] || "")
    model_id = String.trim(params["model_id"] || "")
    display_name = String.trim(params["display_name"] || "")
    display_name = if display_name == "", do: "custom", else: display_name

    cond do
      base_url == "" ->
        {:noreply, assign(socket, account_error: "Base URL is required.")}

      api_key == "" ->
        {:noreply, assign(socket, account_error: "API key is required.")}

      model_id == "" ->
        {:noreply, assign(socket, account_error: "Model ID is required.")}

      true ->
        send(self(), {:account_save_compatible, base_url, api_key, model_id, display_name})
        {:noreply, assign(socket, account_sub: :saving, account_error: nil)}
    end
  end

  # ---------- Integration events ----------

  def handle_event("brave_enable_managed", _params, socket) do
    pid = self()

    Task.start(fn ->
      result = SearchProxy.register_device()
      send(pid, {:brave_register_result, result})
    end)

    {:noreply, assign(socket, brave_registering: true, brave_error: nil)}
  end

  def handle_event("brave_show_byok", _params, socket) do
    {:noreply, assign(socket, brave_mode: :byok_form)}
  end

  def handle_event("brave_back", _params, socket) do
    {:noreply, assign(socket, brave_mode: :not_configured, brave_error: nil)}
  end

  def handle_event("brave_submit_api_key", %{"api_key" => key}, socket) do
    key = String.trim(key)

    if key == "" do
      {:noreply, assign(socket, :brave_error, "Please paste your Brave API key.")}
    else
      case IntegrationsConfig.write_brave_key(key) do
        :ok ->
          Task.start(fn -> Commands.impl().start_gateway() end)

          {:noreply,
           socket
           |> assign(brave_mode: :byok, brave_error: nil)
           |> put_flash(:info, "Web search enabled. Gateway restarting...")}

        {:error, msg} ->
          {:noreply, assign(socket, :brave_error, msg)}
      end
    end
  end

  def handle_event("brave_remove", _params, socket) do
    case IntegrationsConfig.remove_search_config() do
      :ok ->
        Task.start(fn -> Commands.impl().start_gateway() end)

        {:noreply,
         socket
         |> assign(brave_mode: :not_configured, brave_error: nil, brave_usage: nil)
         |> put_flash(:info, "Web search removed. Gateway restarting...")}

      {:error, msg} ->
        {:noreply, assign(socket, :brave_error, msg)}
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

    # In preview mode we intentionally freeze live status polling so scenarios
    # stay deterministic for review links.
    if socket.assigns[:preview_scenario] do
      {:noreply, socket}
    else
      # Run status checks in a separate process so the LiveView stays responsive
      # (gateway_status can take 10+ seconds due to RPC probe timeout).
      pid = self()

      Task.start(fn ->
        gateway = Commands.impl().gateway_status()
        internet = Commands.impl().check_internet()
        autoheal = Commands.impl().autoheal_status()
        autoheal_log = Commands.impl().autoheal_recent_log(12)

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

        ethernet_connected = Commands.impl().has_ethernet_ip()

        brave_mode = IntegrationsConfig.search_mode()

        brave_usage =
          case IntegrationsConfig.managed_token() do
            nil ->
              nil

            token ->
              case SearchProxy.get_usage(token) do
                {:ok, usage} -> usage
                _ -> nil
              end
          end

        tailscale = Commands.impl().tailscale_status()
        node_detail = Clawrig.Node.Client.status_detail()

        send(
          pid,
          {:status_result, gateway, internet, wifi_ssid, ethernet_connected, brave_mode,
           brave_usage, tailscale, autoheal, autoheal_log, node_detail}
        )
      end)

      {:noreply, socket}
    end
  end

  def handle_info(
        {:status_result, gateway, internet, wifi_ssid, ethernet_connected, brave_mode,
         brave_usage, tailscale, autoheal, autoheal_log, node_detail},
        socket
      ) do
    if socket.assigns[:preview_scenario] do
      {:noreply, socket}
    else
      openai_status =
        if State.get(:provider_done), do: :connected, else: :disconnected

      account_sub =
        cond do
          socket.assigns.account_sub != :idle -> socket.assigns.account_sub
          openai_status == :connected -> :idle
          true -> :choose_type
        end

      # Don't overwrite brave_mode if user is in the BYOK form
      current_brave_mode =
        if socket.assigns.brave_mode == :byok_form,
          do: :byok_form,
          else: brave_mode

      tailscale_effective = socket.assigns[:tailscale_dev_override] || tailscale

      {:noreply,
       socket
       |> assign(:gateway_status, gateway)
       |> assign(:internet, internet)
       |> assign(:wifi_ssid, wifi_ssid)
       |> assign(:ethernet_connected, ethernet_connected)
       |> assign(:openai_status, openai_status)
       |> assign(:account_sub, account_sub)
       |> assign(:brave_mode, current_brave_mode)
       |> assign(:brave_usage, brave_usage)
       |> assign(:tailscale, tailscale_effective)
       |> assign(:autoheal, autoheal)
       |> assign(:autoheal_log, autoheal_log)
       |> assign(:node_detail, node_detail)}
    end
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

  def handle_info({:update_status, status}, socket) do
    {update_status, update_version} = normalize_update_status(status)

    {:noreply,
     socket
     |> assign(:update_status, update_status)
     |> assign(:update_version, update_version)}
  end

  def handle_info({:node_status, status}, socket) do
    {:noreply, assign(socket, :node_status, status)}
  end

  def handle_info({:node_status_detail, detail}, socket) do
    {:noreply, assign(socket, :node_detail, detail)}
  end

  def handle_info({:tailscale_install_result, result}, socket) do
    case result do
      :ok ->
        tailscale = Commands.impl().tailscale_status()

        {:noreply,
         assign(socket,
           tailscale: tailscale,
           tailscale_installing: false,
           tailscale_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, tailscale_installing: false, tailscale_error: reason)}
    end
  end

  def handle_info({:tailscale_result, result}, socket) do
    case result do
      :ok ->
        tailscale = Commands.impl().tailscale_status()

        {:noreply,
         assign(socket, tailscale: tailscale, tailscale_connecting: false, tailscale_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, tailscale_connecting: false, tailscale_error: reason)}
    end
  end

  def handle_info({ClawrigWeb.WifiComponent, {:wifi_connected, ssid}}, socket) do
    {:noreply, assign(socket, :wifi_ssid, ssid)}
  end

  # ---------- Brave registration info ----------

  def handle_info({:brave_register_result, {:ok, %{"token" => token}}}, socket) do
    case IntegrationsConfig.write_managed_search(token) do
      :ok ->
        Task.start(fn -> Commands.impl().start_gateway() end)

        {:noreply,
         socket
         |> assign(brave_mode: :managed, brave_registering: false, brave_error: nil)
         |> put_flash(:info, "Web search enabled. Gateway restarting...")}

      {:error, msg} ->
        {:noreply, assign(socket, brave_registering: false, brave_error: msg)}
    end
  end

  def handle_info({:brave_register_result, {:error, msg}}, socket) do
    {:noreply, assign(socket, brave_registering: false, brave_error: msg)}
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
      result = Clawrig.OpenAI.Credentials.write(oauth_creds)

      # Also write Codex CLI auth so self-healing diagnostics can use the same tokens
      if result == :ok, do: Clawrig.Auth.CodexAuth.write_auth(oauth_creds)

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

  def handle_info({:account_save_compatible, base_url, api_key, model_id, display_name}, socket) do
    pid = self()

    Task.start(fn ->
      result = Clawrig.Provider.Config.write_compatible(base_url, api_key, model_id, display_name)
      send(pid, {:account_save_compatible_result, result, display_name, base_url, model_id})
    end)

    {:noreply, assign(socket, account_sub: :saving, account_error: nil)}
  end

  def handle_info(
        {:account_save_compatible_result, :ok, display_name, base_url, model_id},
        socket
      ) do
    State.merge(%{
      provider_done: true,
      provider_type: "openai-compatible",
      provider_auth_method: "api-key",
      provider_name: display_name,
      provider_base_url: base_url,
      provider_model_id: model_id
    })

    Task.start(fn -> Commands.impl().start_gateway() end)

    {:noreply,
     socket
     |> assign(
       openai_status: :connected,
       account_sub: :idle,
       account_provider_type: "openai-compatible",
       account_error: nil
     )
     |> put_flash(:info, "Provider connected. Gateway restarting...")}
  end

  def handle_info({:account_save_compatible_result, {:error, msg}, _, _, _}, socket) do
    {:noreply,
     assign(socket,
       account_sub: :error,
       account_error: "Could not save provider config. #{msg}"
     )}
  end

  def handle_info({:account_save_result, :ok, method}, socket) do
    method_str = if method == :api_key, do: "api-key", else: "device-code"

    State.merge(%{
      provider_done: true,
      provider_type: "openai",
      provider_auth_method: method_str,
      openai_device_auth_id: nil,
      openai_user_code: nil
    })

    Task.start(fn -> Commands.impl().start_gateway() end)

    {:noreply,
     socket
     |> assign(
       openai_status: :connected,
       account_sub: :idle,
       account_provider_type: "openai",
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

  defp normalize_update_status(:checking), do: {:checking, nil}
  defp normalize_update_status({:ok, :up_to_date}), do: {:up_to_date, nil}
  defp normalize_update_status({:ok, :update_available, v}), do: {:available, v}
  defp normalize_update_status({:ok, :downloading, v}), do: {:downloading, v}
  defp normalize_update_status({:ok, :installing, v}), do: {:installing, v}
  defp normalize_update_status({:ok, :updated, v}), do: {:updated, v}
  defp normalize_update_status({:ok, :pending_recovery_path, v}), do: {{:pending_recovery_path, "A new update (v#{v}) is ready, but ClawRig is waiting to install it until your device is reachable."}, v}
  defp normalize_update_status({:ok, :pending_recovery_path, v, _reason}), do: {{:pending_recovery_path, "A new update (v#{v}) is ready. To avoid interruptions, install it when you’re at home or connected through Tailscale."}, v}
  defp normalize_update_status({:error, reason}), do: {{:error, reason}, nil}
  defp normalize_update_status(_), do: {nil, nil}

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

  defp dev_tailscale_bypass_enabled? do
    System.get_env("CLAWRIG_ENABLE_DEV_TAILSCALE_BYPASS", "false") == "true"
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

  def autoheal_health_label(status) do
    case status do
      "healthy" -> "Healthy"
      "degraded" -> "Degraded"
      "unknown" -> "Unknown"
      other when is_binary(other) -> String.capitalize(other)
      _ -> "Unknown"
    end
  end

  def tab_class(live_action, tab) when live_action == tab, do: "dash-tab active"
  def tab_class(_live_action, _tab), do: "dash-tab"
end
