defmodule ClawrigWeb.WizardLive do
  use ClawrigWeb, :live_view
  require Logger

  alias Clawrig.System.Commands
  alias Clawrig.Wizard.{State, Installer, Launcher, Telegram}

  @steps [:preflight, :openai, :telegram, :receipt]
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
     |> assign(:openai_done, state.openai_done || false)
     |> assign(:openai_status, nil)
     |> assign(:openai_error, nil)
     |> assign(:openai_sub, openai_sub_on_mount(state))
     |> assign(:openai_user_code, state.openai_user_code)
     |> assign(:openai_device_auth_id, state.openai_device_auth_id)
     |> assign(:openai_poll_interval, 5)
     |> assign(:openai_polling, false)
     |> assign(:openai_poll_count, 0)
     |> assign(:openai_resuming, false)
     |> assign(:tg_token, state.tg_token)
     |> assign(:tg_chat_id, state.tg_chat_id)
     |> assign(:tg_bot_name, state.tg_bot_name)
     |> assign(:tg_bot_username, state.tg_bot_username)
     |> assign(:tg_sub, if(state.tg_chat_id, do: :done, else: :intro))
     |> assign(:tg_status, nil)
     |> assign(:tg_error, nil)
     |> assign(:tg_polling, false)
     |> assign(:finishing, false)
     |> assign(:finish_message, nil)
     |> assign(:local_ip, state.local_ip)
     |> assign(:ip_confirmed, false)
     |> maybe_resume_device_code_polling()
     |> then(fn s -> if s.assigns.step == :receipt, do: detect_and_assign_ip(s), else: s end)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
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

  # OpenAI — device code flow
  def handle_event("openai_start_device_code", _params, socket) do
    send(self(), :do_request_user_code)
    {:noreply, assign(socket, openai_sub: :device_code, openai_error: nil)}
  end

  def handle_event("openai_use_api_key", _params, socket) do
    {:noreply, assign(socket, openai_sub: :api_key, openai_error: nil)}
  end

  def handle_event("openai_back_to_choose", _params, socket) do
    State.merge(%{openai_device_auth_id: nil, openai_user_code: nil})

    {:noreply,
     assign(socket,
       openai_sub: :choose,
       openai_error: nil,
       openai_polling: false,
       openai_user_code: nil,
       openai_device_auth_id: nil,
       openai_poll_count: 0
     )}
  end

  # Trigger immediate poll when user returns to the tab
  def handle_event("page_visible", _params, socket) do
    if socket.assigns.openai_polling and socket.assigns.openai_sub == :device_code do
      send(self(), :openai_poll)
    end

    {:noreply, socket}
  end

  # OpenAI — API key paste (fallback)
  def handle_event("submit_api_key", %{"api_key" => key}, socket) do
    key = String.trim(key)

    if key == "" do
      {:noreply, assign(socket, :openai_error, "Please paste your API key.")}
    else
      socket = assign(socket, openai_status: :saving, openai_error: nil)
      send(self(), {:do_save_api_key, key})
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

  def handle_event("tg_skip", _params, socket) do
    {:noreply, socket}
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
           openai_sub: :device_code,
           openai_user_code: code,
           openai_device_auth_id: id,
           openai_poll_interval: interval,
           openai_polling: true,
           openai_poll_count: 0
         )}

      {:error, :not_enabled} ->
        {:noreply,
         assign(socket,
           openai_sub: :error,
           openai_error:
             "Device code authorization isn't enabled on your OpenAI account. " <>
               "Enable it in ChatGPT Settings > Security > \"Device code authorization for Codex\", then try again."
         )}

      {:error, msg} ->
        {:noreply, assign(socket, openai_sub: :error, openai_error: "#{msg}")}
    end
  end

  def handle_info(:openai_poll, socket) do
    if !socket.assigns.openai_polling || socket.assigns.openai_sub != :device_code do
      {:noreply, assign(socket, openai_polling: false)}
    else
      if socket.assigns.openai_poll_count >= @openai_poll_timeout_count do
        {:noreply,
         assign(socket,
           openai_sub: :error,
           openai_polling: false,
           openai_error: "Authorization timed out. Please try again."
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
               openai_sub: :error,
               openai_polling: false,
               openai_error: "#{msg}"
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
        {:noreply, assign(socket, openai_status: :saving)}

      {:ok, api_key} when is_binary(api_key) ->
        Logger.info("[DeviceCode] Got API key (#{String.slice(api_key, 0..7)}...)")
        send(self(), {:do_save_api_key, api_key})
        {:noreply, assign(socket, openai_status: :saving)}

      {:error, msg} ->
        Logger.error("[DeviceCode] Token exchange failed: #{msg}")
        {:noreply, assign(socket, openai_sub: :error, openai_error: "#{msg}")}
    end
  end

  def handle_info({:do_save_oauth_creds, oauth_creds}, socket) do
    case Clawrig.OpenAI.Credentials.write(oauth_creds) do
      :ok ->
        State.merge(%{
          openai_done: true,
          openai_auth_method: "device-code",
          openai_device_auth_id: nil,
          openai_user_code: nil
        })

        {:noreply,
         assign(socket,
           openai_done: true,
           openai_sub: :done,
           openai_status: :saved,
           openai_error: nil
         )}

      {:error, msg} ->
        {:noreply,
         assign(socket,
           openai_status: nil,
           openai_sub: :error,
           openai_error: "Could not save credentials. #{msg}"
         )}
    end
  end

  def handle_info({:do_save_api_key, key}, socket) do
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
        openai_done: true,
        openai_auth_method: "api-key",
        openai_device_auth_id: nil,
        openai_user_code: nil
      })

      {:noreply,
       assign(socket,
         openai_done: true,
         openai_sub: :done,
         openai_status: :saved,
         openai_error: nil
       )}
    else
      {:noreply,
       assign(socket,
         openai_status: nil,
         openai_sub: :error,
         openai_error: "Could not save API key. #{String.trim(output)}"
       )}
    end
  end

  def handle_info({:do_tg_validate, token}, socket) do
    case Telegram.validate_token(token) do
      {:ok, %{bot_name: bot_name, bot_username: bot_username}} ->
        State.merge(%{tg_token: token, tg_bot_name: bot_name, tg_bot_username: bot_username})
        send(self(), :tg_start_polling)

        {:noreply,
         assign(socket,
           tg_token: token,
           tg_bot_name: bot_name,
           tg_bot_username: bot_username,
           tg_sub: :chat,
           tg_status: nil,
           tg_error: nil
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
      case Telegram.detect_chat(socket.assigns.tg_token) do
        {:ok, %{chat_id: chat_id, first_name: _first_name}} ->
          State.merge(%{tg_chat_id: chat_id})
          Telegram.save_config(socket.assigns.tg_token, chat_id, socket.assigns.tg_bot_name)

          {:noreply, assign(socket, tg_chat_id: chat_id, tg_sub: :done, tg_polling: false)}

        :no_messages ->
          Process.send_after(self(), :tg_poll, 2000)
          {:noreply, socket}
      end
    end
  end

  def handle_info(:do_finish, socket) do
    state = State.get()

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
    Task.start(fn -> Commands.impl().start_gateway() end)

    {:noreply, socket |> put_flash(:info, "Setup complete!") |> redirect(to: "/")}
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
      openai: "OpenAI",
      telegram: "Optional Telegram",
      receipt: "Complete"
    }[step] || ""
  end

  def can_next?(assigns) do
    case assigns.step do
      :preflight -> assigns.preflight_done
      :openai -> assigns.openai_done
      :telegram -> true
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
    if socket.assigns.openai_sub == :device_code and socket.assigns.openai_device_auth_id do
      Logger.info(
        "[DeviceCode] Resuming polling on reconnect for #{socket.assigns.openai_user_code}"
      )

      Process.send_after(self(), :openai_poll, 1000)
      assign(socket, openai_polling: true, openai_poll_count: 0, openai_resuming: true)
    else
      socket
    end
  end

  defp openai_sub_on_mount(state) do
    cond do
      state.openai_done -> :done
      state.openai_device_auth_id != nil -> :device_code
      true -> :choose
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

  def openai_title(:done), do: "Connected to OpenAI"
  def openai_title(:error), do: "Something went wrong"
  def openai_title(:device_code), do: "Sign in with OpenAI"
  def openai_title(:api_key), do: "API key"
  def openai_title(_), do: "OpenAI"

  def openai_title_class(:done), do: "pass"
  def openai_title_class(:error), do: "fail"
  def openai_title_class(_), do: ""

  def openai_desc(:done), do: "Your API key is configured."

  def openai_desc(:device_code),
    do: "Enter the code below on your phone to authorize this device."

  def openai_desc(:api_key), do: "Paste your OpenAI API key to connect."
  def openai_desc(_), do: "Connect your OpenAI account to get started."
end
