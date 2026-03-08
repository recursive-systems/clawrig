defmodule ClawrigWeb.WizardLive do
  use ClawrigWeb, :live_view
  require Logger

  alias Clawrig.System.Commands
  alias Clawrig.Wizard.{State, Installer, Launcher, Telegram}
  alias Clawrig.DashboardAuth

  @steps [:preflight, :provider, :telegram, :security, :receipt]
  @openai_poll_timeout_count 180

  @impl true
  def mount(_params, _session, socket) do
    state = State.get()

    {:ok,
     socket
     |> assign(:step, if(state.step in @steps, do: state.step, else: :preflight))
     |> assign(:steps, @steps)
     |> assign(:mode, state.mode || :new)
     |> assign(:preflight_done, state.preflight_done)
     |> assign(:preflight_status, if(state.preflight_done, do: :pass))
     # Provider state (replaces openai_*)
     |> assign(:provider_done, state.provider_done || false)
     |> assign(:provider_status, nil)
     |> assign(:provider_error, nil)
     |> assign(:dev_auth_bypass_enabled, dev_auth_bypass_enabled?())
     |> assign(:provider_sub, provider_sub_on_mount(state))
     |> assign(:provider_type, state.provider_type)
     |> assign(:provider_name, state.provider_name)
     |> assign(:provider_base_url, state.provider_base_url)
     |> assign(:provider_model_id, state.provider_model_id)
     # OpenAI device code polling (only used when provider_type == "openai")
     |> assign(:openai_user_code, state.openai_user_code)
     |> assign(:openai_device_auth_id, state.openai_device_auth_id)
     |> assign(:openai_poll_interval, 5)
     |> assign(:openai_polling, false)
     |> assign(:openai_poll_count, 0)
     |> assign(:openai_resuming, false)
     # Telegram
     |> assign(:tg_token, state.tg_token)
     |> assign(:tg_chat_id, state.tg_chat_id)
     |> assign(:tg_bot_name, state.tg_bot_name)
     |> assign(:tg_bot_username, state.tg_bot_username)
     |> assign(:tg_sub, telegram_sub_on_mount(state))
     |> assign(:tg_baseline_update_id, Map.get(state, :tg_baseline_update_id))
     |> assign(:tg_status, nil)
     |> assign(:tg_error, nil)
     |> assign(:tg_polling, false)
     |> assign(:dashboard_auth_done, state.dashboard_auth_done || DashboardAuth.configured?())
     |> assign(:dashboard_auth_error, nil)
     |> assign(:dashboard_auth_strength, nil)
     |> assign(:dashboard_password_value, "")
     |> assign(:dashboard_password_confirm_value, "")
     |> assign(:finishing, false)
     |> assign(:finish_message, nil)
     |> assign(:local_ip, state.local_ip)
     |> assign(:ip_confirmed, false)
     |> assign(:mdns_url, Clawrig.DeviceIdentity.mdns_url())
     |> maybe_resume_device_code_polling()
     |> then(fn s -> if s.assigns.step == :receipt, do: detect_and_assign_ip(s), else: s end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if preview_enabled?() and is_map(params) and params["preview_step"] in Enum.map(@steps, &Atom.to_string/1) do
        step = String.to_existing_atom(params["preview_step"])

        socket
        |> assign(:step, step)
        |> maybe_set_preview_substate(params)
      else
        socket
      end

    {:noreply, socket}
  end

  # Navigation
  @impl true
  def handle_event("nav_next", _params, socket) do
    current_idx = step_index(socket.assigns.step)

    if current_idx < length(@steps) - 1 do
      next = Enum.at(@steps, current_idx + 1)
      State.put(:step, next)
      socket = assign(socket, :step, next)
      socket = if next == :receipt, do: detect_and_assign_ip(socket), else: socket
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("nav_prev", _params, socket) do
    current_idx = step_index(socket.assigns.step)

    if current_idx > 0 do
      prev = Enum.at(@steps, current_idx - 1)
      State.put(:step, prev)
      {:noreply, assign(socket, :step, prev)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("goto_step", %{"step" => step}, socket) do
    step = String.to_existing_atom(step)

    if step in @steps do
      State.put(:step, step)
      {:noreply, assign(socket, :step, step)}
    else
      {:noreply, socket}
    end
  end

  # Preflight
  def handle_event("run_preflight", _params, socket) do
    socket = assign(socket, :preflight_status, :checking)
    send(self(), :do_preflight)
    {:noreply, socket}
  end

  # Provider type selection
  def handle_event("choose_openai", _params, socket) do
    State.put(:provider_type, "openai")
    {:noreply, assign(socket, provider_type: "openai", provider_sub: :openai_choose)}
  end

  def handle_event("choose_compatible", _params, socket) do
    State.put(:provider_type, "openai-compatible")
    {:noreply, assign(socket, provider_type: "openai-compatible", provider_sub: :compat_form)}
  end

  def handle_event("provider_back_to_type", _params, socket) do
    State.merge(%{provider_type: nil, openai_device_auth_id: nil, openai_user_code: nil})

    {:noreply,
     assign(socket,
       provider_sub: :choose_type,
       provider_type: nil,
       provider_error: nil,
       openai_polling: false,
       openai_user_code: nil,
       openai_device_auth_id: nil,
       openai_poll_count: 0
     )}
  end

  # OpenAI — device code flow
  def handle_event("openai_start_device_code", _params, socket) do
    send(self(), :do_request_user_code)
    {:noreply, assign(socket, provider_sub: :openai_device_code, provider_error: nil)}
  end

  def handle_event("openai_use_api_key", _params, socket) do
    {:noreply, assign(socket, provider_sub: :openai_api_key, provider_error: nil)}
  end

  def handle_event("openai_back_to_choose", _params, socket) do
    State.merge(%{openai_device_auth_id: nil, openai_user_code: nil})

    {:noreply,
     assign(socket,
       provider_sub: :openai_choose,
       provider_error: nil,
       openai_polling: false,
       openai_user_code: nil,
       openai_device_auth_id: nil,
       openai_poll_count: 0
     )}
  end

  # Trigger immediate poll when user returns to the tab
  def handle_event("page_visible", _params, socket) do
    if socket.assigns.openai_polling and socket.assigns.provider_sub == :openai_device_code do
      send(self(), :openai_poll)
    end

    {:noreply, socket}
  end

  # OpenAI — API key paste (fallback)
  def handle_event("submit_api_key", %{"api_key" => key}, socket) do
    key = String.trim(key)

    if key == "" do
      {:noreply, assign(socket, :provider_error, "Please paste your API key.")}
    else
      socket = assign(socket, provider_status: :saving, provider_error: nil)
      send(self(), {:do_save_api_key, key})
      {:noreply, socket}
    end
  end

  # OpenAI-Compatible — form submission
  def handle_event("submit_compatible", params, socket) do
    base_url = String.trim(params["base_url"] || "")
    api_key = String.trim(params["api_key"] || "")
    model_id = String.trim(params["model_id"] || "")
    display_name = String.trim(params["display_name"] || "")
    display_name = if display_name == "", do: "custom", else: display_name

    cond do
      base_url == "" ->
        {:noreply, assign(socket, provider_error: "Base URL is required.")}

      api_key == "" ->
        {:noreply, assign(socket, provider_error: "API key is required.")}

      model_id == "" ->
        {:noreply, assign(socket, provider_error: "Model ID is required.")}

      true ->
        socket = assign(socket, provider_status: :saving, provider_error: nil)
        send(self(), {:do_save_compatible, base_url, api_key, model_id, display_name})
        {:noreply, socket}
    end
  end

  # Telegram
  def handle_event("tg_start", _params, socket) do
    {:noreply, assign(socket, :tg_sub, :create)}
  end

  def handle_event("tg_validate", %{"token" => token}, socket) do
    token = String.trim(token)

    if token == "" do
      {:noreply, assign(socket, :tg_error, "Please paste your bot token.")}
    else
      socket = assign(socket, tg_status: :validating, tg_error: nil)
      send(self(), {:do_tg_validate, token})
      {:noreply, socket}
    end
  end

  def handle_event("tg_check_now", _params, socket) do
    send(self(), :tg_poll)
    {:noreply, assign(socket, tg_status: :checking, tg_error: nil)}
  end

  def handle_event("tg_skip", _params, socket) do
    {:noreply, socket}
  end

  # Security
  def handle_event("validate_dashboard_password", %{"password" => password, "password_confirm" => confirm}, socket) do
    password = String.trim(password || "")
    confirm = String.trim(confirm || "")

    error =
      cond do
        confirm == "" -> nil
        password != confirm -> "Passwords do not match"
        true -> nil
      end

    {:noreply,
     assign(socket,
       dashboard_password_value: password,
       dashboard_password_confirm_value: confirm,
       dashboard_auth_error: error,
       dashboard_auth_strength: DashboardAuth.password_strength(password)
     )}
  end

  def handle_event("set_dashboard_password", %{"password" => password, "password_confirm" => confirm}, socket) do
    password = String.trim(password || "")
    confirm = String.trim(confirm || "")

    cond do
      password == "" ->
        {:noreply,
         assign(socket,
           dashboard_auth_error: "Password is required",
           dashboard_auth_strength: nil,
           dashboard_password_value: password,
           dashboard_password_confirm_value: confirm
         )}

      password != confirm ->
        {:noreply,
         assign(socket,
           dashboard_auth_error: "Passwords do not match",
           dashboard_auth_strength: DashboardAuth.password_strength(password),
           dashboard_password_value: password,
           dashboard_password_confirm_value: confirm
         )}

      true ->
        case DashboardAuth.set_password(password) do
          :ok ->
            State.merge(%{dashboard_auth_done: true, step: :receipt})

            {:noreply,
             socket
             |> assign(
               dashboard_auth_done: true,
               dashboard_auth_error: nil,
               dashboard_auth_strength: DashboardAuth.password_strength(password),
               dashboard_password_value: "",
               dashboard_password_confirm_value: "",
               step: :receipt
             )
             |> detect_and_assign_ip()}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               dashboard_auth_error: reason,
               dashboard_auth_strength: DashboardAuth.password_strength(password),
               dashboard_password_value: password,
               dashboard_password_confirm_value: confirm
             )}
        end
    end
  end

  # IP confirmation gate
  def handle_event("confirm_ip", _params, socket) do
    {:noreply, assign(socket, :ip_confirmed, !socket.assigns.ip_confirmed)}
  end

  # Finish
  def handle_event("finish", _params, socket) do
    send(self(), :do_finish)
    {:noreply, assign(socket, :finishing, true)}
  end

  # Async handlers
  @impl true
  def handle_info(:do_preflight, socket) do
    online = Installer.check_internet()
    State.put(:preflight_done, online)

    {:noreply,
     assign(socket,
       preflight_done: online,
       preflight_status: if(online, do: :pass, else: :fail)
     )}
  end

  def handle_info(:do_request_user_code, socket) do
    case device_code_impl().request_user_code() do
      {:ok, %{device_auth_id: id, user_code: code, interval: interval}} ->
        Logger.info("[DeviceCode] Got user_code=#{code} interval=#{interval}")
        State.merge(%{openai_device_auth_id: id, openai_user_code: code})
        Process.send_after(self(), :openai_poll, interval * 1000)

        {:noreply,
         assign(socket,
           provider_sub: :openai_device_code,
           openai_user_code: code,
           openai_device_auth_id: id,
           openai_poll_interval: interval,
           openai_polling: true,
           openai_poll_count: 0
         )}

      {:error, :not_enabled} ->
        {:noreply,
         assign(socket,
           provider_sub: :error,
           provider_error:
             "Device code authorization isn't enabled on your OpenAI account. " <>
               "Enable it in ChatGPT Settings > Security > \"Device code authorization for Codex\", then try again."
         )}

      {:error, msg} ->
        {:noreply, assign(socket, provider_sub: :error, provider_error: "#{msg}")}
    end
  end

  def handle_info(:openai_poll, socket) do
    if !socket.assigns.openai_polling || socket.assigns.provider_sub != :openai_device_code do
      {:noreply, assign(socket, openai_polling: false)}
    else
      if socket.assigns.openai_poll_count >= @openai_poll_timeout_count do
        {:noreply,
         assign(socket,
           provider_sub: :error,
           openai_polling: false,
           provider_error: "Authorization timed out. Please try again."
         )}
      else
        case device_code_impl().poll_authorization(
               socket.assigns.openai_device_auth_id,
               socket.assigns.openai_user_code
             ) do
          :pending ->
            Process.send_after(self(), :openai_poll, socket.assigns.openai_poll_interval * 1000)
            {:noreply, assign(socket, openai_poll_count: socket.assigns.openai_poll_count + 1)}

          {:ok, auth_data} ->
            Logger.info("[DeviceCode] Authorization received, exchanging tokens")
            send(self(), {:do_exchange_tokens, auth_data})
            {:noreply, assign(socket, openai_polling: false)}

          {:error, msg} ->
            Logger.error("[DeviceCode] Poll error: #{msg}")

            {:noreply,
             assign(socket,
               provider_sub: :error,
               openai_polling: false,
               provider_error: "#{msg}"
             )}
        end
      end
    end
  end

  def handle_info({:do_exchange_tokens, auth_data}, socket) do
    Logger.info("[DeviceCode] Exchanging tokens...")

    case device_code_impl().complete_flow(auth_data) do
      {:ok, oauth_creds} when is_map(oauth_creds) ->
        Logger.info("[DeviceCode] Got OAuth credentials for #{oauth_creds[:email] || "unknown"}")
        send(self(), {:do_save_oauth_creds, oauth_creds})
        {:noreply, assign(socket, provider_status: :saving)}

      {:ok, api_key} when is_binary(api_key) ->
        Logger.info("[DeviceCode] Got API key (#{String.slice(api_key, 0..7)}...)")
        send(self(), {:do_save_api_key, api_key})
        {:noreply, assign(socket, provider_status: :saving)}

      {:error, msg} ->
        Logger.error("[DeviceCode] Token exchange failed: #{msg}")
        {:noreply, assign(socket, provider_sub: :error, provider_error: "#{msg}")}
    end
  end

  def handle_info({:do_save_oauth_creds, oauth_creds}, socket) do
    case Clawrig.OpenAI.Credentials.write(oauth_creds) do
      :ok ->
        # Also write Codex CLI auth so self-healing diagnostics can use the same tokens
        Clawrig.Auth.CodexAuth.write_auth(oauth_creds)

        State.merge(%{
          provider_done: true,
          provider_type: "openai",
          provider_auth_method: "device-code",
          openai_device_auth_id: nil,
          openai_user_code: nil
        })

        {:noreply,
         assign(socket,
           provider_done: true,
           provider_sub: :done,
           provider_status: :saved,
           provider_error: nil
         )}

      {:error, msg} ->
        {:noreply,
         assign(socket,
           provider_status: nil,
           provider_sub: :error,
           provider_error: "Could not save credentials. #{msg}"
         )}
    end
  end

  def handle_info({:do_save_api_key, key}, socket) do
    if dev_auth_bypass_enabled?() and String.starts_with?(key, "sk_test_") do
      State.merge(%{
        provider_done: true,
        provider_type: "openai",
        provider_auth_method: "api-key-mock",
        openai_device_auth_id: nil,
        openai_user_code: nil
      })

      {:noreply,
       socket
       |> put_flash(:info, "Dev mode: mock provider auth enabled")
       |> assign(
         provider_done: true,
         provider_sub: :done,
         provider_status: :saved,
         provider_error: nil
       )}
    else
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

      if exit_code == 0 do
        State.merge(%{
          provider_done: true,
          provider_type: "openai",
          provider_auth_method: "api-key",
          openai_device_auth_id: nil,
          openai_user_code: nil
        })

        {:noreply,
         assign(socket,
           provider_done: true,
           provider_sub: :done,
           provider_status: :saved,
           provider_error: nil
         )}
      else
        {:noreply,
         assign(socket,
           provider_status: nil,
           provider_sub: :error,
           provider_error: "Could not save API key. #{String.trim(output)}"
         )}
      end
    end
  end

  def handle_info({:do_save_compatible, base_url, api_key, model_id, display_name}, socket) do
    case Clawrig.Provider.Config.write_compatible(base_url, api_key, model_id, display_name) do
      :ok ->
        State.merge(%{
          provider_done: true,
          provider_type: "openai-compatible",
          provider_auth_method: "api-key",
          provider_name: display_name,
          provider_base_url: base_url,
          provider_model_id: model_id
        })

        {:noreply,
         assign(socket,
           provider_done: true,
           provider_sub: :done,
           provider_status: :saved,
           provider_error: nil,
           provider_name: display_name,
           provider_base_url: base_url,
           provider_model_id: model_id
         )}

      {:error, msg} ->
        {:noreply,
         assign(socket,
           provider_status: nil,
           provider_sub: :error,
           provider_error: "Could not save provider config. #{msg}"
         )}
    end
  end

  def handle_info({:do_tg_validate, token}, socket) do
    case Telegram.validate_token(token) do
      {:ok, %{bot_name: bot_name, bot_username: bot_username}} ->
        baseline_update_id = Telegram.latest_update_id(token)

        State.merge(%{
          tg_token: token,
          tg_bot_name: bot_name,
          tg_bot_username: bot_username,
          tg_baseline_update_id: baseline_update_id,
          tg_chat_id: nil
        })

        {:noreply,
         assign(socket,
           tg_token: token,
           tg_bot_name: bot_name,
           tg_bot_username: bot_username,
           tg_chat_id: nil,
           tg_sub: :chat,
           tg_status: :waiting_for_start,
           tg_error: nil,
           tg_baseline_update_id: baseline_update_id
         )}

      {:error, msg} ->
        {:noreply, assign(socket, tg_status: nil, tg_error: msg)}
    end
  end

  def handle_info(:tg_start_polling, socket) do
    if socket.assigns.tg_chat_id do
      {:noreply, socket}
    else
      Process.send_after(self(), :tg_poll, 2000)
      {:noreply, assign(socket, :tg_polling, true)}
    end
  end

  def handle_info(:tg_poll, socket) do
    if socket.assigns.tg_sub != :chat || socket.assigns.tg_chat_id do
      {:noreply, assign(socket, :tg_polling, false)}
    else
      case Telegram.detect_chat(socket.assigns.tg_token, socket.assigns[:tg_baseline_update_id]) do
        {:ok, %{chat_id: chat_id, first_name: _first_name, update_id: update_id}} ->
          State.merge(%{tg_chat_id: chat_id, tg_baseline_update_id: update_id})
          Telegram.save_config(socket.assigns.tg_token, chat_id, socket.assigns.tg_bot_name)

          {:noreply,
           assign(socket,
             tg_chat_id: chat_id,
             tg_sub: :done,
             tg_polling: false,
             tg_baseline_update_id: update_id
           )}

        :no_messages ->
          {:noreply,
           assign(socket,
             tg_status: :waiting_for_start,
             tg_error: "No new /start found yet. Send /start to your bot, then tap Check now."
           )}
      end
    end
  end

  def handle_info(:do_finish, socket) do
    state = State.get()

    if not DashboardAuth.configured?() do
      {:noreply,
       socket
       |> assign(:finishing, false)
       |> put_flash(:error, "Please set your dashboard password before finishing setup.")}
    else
      # Apply runtime-only config (Telegram channel) and write audit trail
      Launcher.finalize(state.mode, state.tg_token, state.tg_chat_id)

      # Detect and store the best IP for dashboard use
      ip = Commands.impl().detect_local_ip()
      if ip, do: State.put(:local_ip, ip)

      # Auto-detect network method if user went directly to /setup via LAN
      if state.network_method == nil do
        if Commands.impl().has_ethernet_ip() do
          State.put(:network_method, :ethernet)
        end
      end

      {:ok, _receipt} = Launcher.write_receipt(State.get())

      # Mark OOBE as complete — this unlocks the gateway watchdog
      path = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")

      # Tear down hotspot if still running.
      # WiFi flow: already torn down by safe_connect, this is a no-op.
      # Ethernet flow: hotspot is still up and must be stopped.
      Clawrig.Wifi.Manager.stop_hotspot()

      # Best-effort gateway start (non-blocking).
      # If this fails, the watchdog will pick it up within ~2 minutes.
      Task.start(fn ->
        Commands.impl().start_gateway()
        # Give startup a brief head start, then send a clear readiness hint in Telegram.
        Process.sleep(3000)
        Telegram.send_setup_complete(state.tg_token, state.tg_chat_id)
      end)

      {:noreply, socket |> put_flash(:info, "Setup complete!") |> redirect(to: "/")}
    end
  end

  # Helpers

  def step_progress(step) do
    idx = Enum.find_index(@steps, &(&1 == step)) || 0
    round((idx + 1) / length(@steps) * 100)
  end

  def step_number(step) do
    (Enum.find_index(@steps, &(&1 == step)) || 0) + 1
  end

  def step_title(step) do
    %{
      preflight: "Connectivity",
      provider: "AI Provider",
      telegram: "Optional Telegram",
      security: "Secure Dashboard",
      receipt: "Complete"
    }[step] || ""
  end

  def can_next?(assigns) do
    case assigns.step do
      :preflight -> assigns.preflight_done
      :provider -> assigns.provider_done
      :telegram -> true
      :security -> assigns.dashboard_auth_done
      :receipt -> true
    end
  end

  def at_start?(step), do: step == :preflight
  def at_end?(step), do: step == :receipt

  def next_label(step, assigns) do
    if step == :telegram && !assigns.tg_chat_id, do: "Skip", else: "Continue"
  end

  defp detect_and_assign_ip(socket) do
    ip = State.get(:local_ip) || Commands.impl().detect_local_ip()
    if ip, do: State.put(:local_ip, ip)
    assign(socket, :local_ip, ip)
  end

  defp device_code_impl do
    Application.get_env(:clawrig, :device_code_module, Clawrig.Wizard.DeviceCode)
  end

  defp maybe_resume_device_code_polling(socket) do
    if socket.assigns.provider_sub == :openai_device_code and
         socket.assigns.openai_device_auth_id do
      Logger.info(
        "[DeviceCode] Resuming polling on reconnect for #{socket.assigns.openai_user_code}"
      )

      Process.send_after(self(), :openai_poll, 1000)
      assign(socket, openai_polling: true, openai_poll_count: 0, openai_resuming: true)
    else
      socket
    end
  end

  defp maybe_set_preview_substate(socket, params) do
    case socket.assigns.step do
      :provider ->
        sub = params["provider_sub"] || "choose_type"

        provider_sub =
          case sub do
            "choose_type" -> :choose_type
            "openai_choose" -> :openai_choose
            "openai_device_code" -> :openai_device_code
            "openai_api_key" -> :openai_api_key
            "compat_form" -> :compat_form
            "done" -> :done
            "error" -> :error
            _ -> :choose_type
          end

        assign(socket, :provider_sub, provider_sub)

      :telegram ->
        # Only force telegram substate when explicitly requested via query param.
        # This prevents links like `tg_sub=create` from snapping users back to token entry
        # after they successfully validate and move forward.
        case params["tg_sub"] do
          nil ->
            socket

          sub ->
            tg_sub =
              case sub do
                "intro" -> :intro
                "create" -> :create
                "chat" -> :chat
                "done" -> :done
                _ -> :intro
              end

            # If token is already present and requested sub is :create, keep current state.
            # This avoids bouncing back to create screen while testing /start flow.
            if tg_sub == :create and socket.assigns[:tg_token] do
              socket
            else
              assign(socket, :tg_sub, tg_sub)
            end
        end

      _ ->
        socket
    end
  end

  defp preview_enabled? do
    System.get_env("CLAWRIG_ENABLE_PREVIEW_STATES", "false") == "true"
  end

  defp dev_auth_bypass_enabled? do
    System.get_env("CLAWRIG_ENABLE_DEV_AUTH_BYPASS", "false") == "true"
  end

  defp telegram_sub_on_mount(state) do
    cond do
      state.tg_chat_id ->
        :done

      state.tg_token ->
        :chat

      true ->
        :intro
    end
  end

  defp provider_sub_on_mount(state) do
    cond do
      state.provider_done ->
        :done

      state.provider_type == "openai" and state.openai_device_auth_id != nil ->
        :openai_device_code

      state.provider_type == "openai" ->
        :openai_choose

      state.provider_type == "openai-compatible" ->
        :compat_form

      true ->
        :choose_type
    end
  end

  # View helpers

  def step_index(step), do: Enum.find_index(@steps, &(&1 == step)) || 0

  def panel_class(current_step, this_step) do
    idx_current = step_index(current_step)
    idx_this = step_index(this_step)

    cond do
      current_step == this_step -> "panel active"
      idx_this < idx_current -> "panel to-left"
      true -> "panel to-right"
    end
  end

  def preflight_label_class(:pass), do: "pass"
  def preflight_label_class(:fail), do: "fail"
  def preflight_label_class(_), do: ""

  def preflight_label(:pass), do: "Connected"
  def preflight_label(:fail), do: "No connection"
  def preflight_label(_), do: "Internet connection"

  def preflight_title_class(:pass), do: "pass"
  def preflight_title_class(:fail), do: "fail"
  def preflight_title_class(_), do: ""

  def preflight_title(:pass), do: "You're online"
  def preflight_title(:fail), do: "No internet"
  def preflight_title(_), do: "Connectivity"

  def preflight_desc(:pass), do: "Internet connection verified."

  def preflight_desc(:fail),
    do: "Connect to Wi-Fi from the taskbar or plug in an ethernet cable, then retry."

  def preflight_desc(:checking), do: "Checking your connection..."
  def preflight_desc(_), do: "Checking your connection..."

  def provider_title(:choose_type), do: "AI Provider"
  def provider_title(:openai_choose), do: "OpenAI"
  def provider_title(:openai_device_code), do: "Sign in with OpenAI"
  def provider_title(:openai_api_key), do: "OpenAI API key"
  def provider_title(:compat_form), do: "Connect Provider"
  def provider_title(:done), do: "Provider Connected"
  def provider_title(:error), do: "Something went wrong"
  def provider_title(_), do: "AI Provider"

  def provider_title_class(:done), do: "pass"
  def provider_title_class(:error), do: "fail"
  def provider_title_class(_), do: ""

  def provider_desc(:choose_type), do: "Choose how to connect your AI provider."
  def provider_desc(:openai_choose), do: "Connect your OpenAI account to get started."

  def provider_desc(:openai_device_code),
    do: "Enter the code below on your phone to authorize this device."

  def provider_desc(:openai_api_key), do: "Paste your OpenAI API key to connect."
  def provider_desc(:compat_form), do: "Enter your provider's OpenAI-compatible endpoint details."
  def provider_desc(:done), do: "Your AI provider is configured."
  def provider_desc(_), do: "Choose how to connect your AI provider."
end
