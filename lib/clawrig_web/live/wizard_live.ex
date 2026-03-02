defmodule ClawrigWeb.WizardLive do
  use ClawrigWeb, :live_view

  alias Clawrig.Wizard.{State, OAuth, Installer, Launcher, Telegram}

  @steps [:preflight, :install, :oauth, :telegram, :launch, :receipt]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Clawrig.PubSub, "oauth")
    end

    state = State.get()

    {:ok,
     socket
     |> assign(:step, state.step || :preflight)
     |> assign(:steps, @steps)
     |> assign(:mode, state.mode || :new)
     |> assign(:preflight_done, state.preflight_done)
     |> assign(:preflight_status, if(state.preflight_done, do: :pass))
     |> assign(:install_done, state.install_done)
     |> assign(:install_version, state.install_version)
     |> assign(:install_status, if(state.install_done, do: :installed))
     |> assign(:oauth_connected, OAuth.connected?(state.oauth_tokens))
     |> assign(:oauth_url, nil)
     |> assign(:oauth_status, if(OAuth.connected?(state.oauth_tokens), do: :connected))
     |> assign(:tg_token, state.tg_token)
     |> assign(:tg_chat_id, state.tg_chat_id)
     |> assign(:tg_bot_name, state.tg_bot_name)
     |> assign(:tg_bot_username, state.tg_bot_username)
     |> assign(:tg_sub, if(state.tg_chat_id, do: :done, else: :intro))
     |> assign(:tg_status, nil)
     |> assign(:tg_error, nil)
     |> assign(:tg_polling, false)
     |> assign(:launch_done, state.launch_done)
     |> assign(:verify_passed, state.verify_passed)
     |> assign(:launch_items, state.launch_items || %{
       configure: :pending,
       gateway: :pending,
       pairing: :pending,
       health: :pending
     })
     |> assign(:launch_messages, state.launch_messages || %{
       configure: "Configure system",
       gateway: "Start gateway",
       pairing: "Pair Telegram",
       health: "Verify connection"
     })
     |> assign(:finish_message, nil)}
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
      {:noreply, assign(socket, :step, next)}
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

  # Install
  def handle_event("check_openclaw", _params, socket) do
    socket = assign(socket, :install_status, :checking)
    send(self(), :do_check_openclaw)
    {:noreply, socket}
  end

  def handle_event("install_openclaw", _params, socket) do
    socket = assign(socket, :install_status, :installing)
    send(self(), :do_install_openclaw)
    {:noreply, socket}
  end

  # OAuth
  def handle_event("start_oauth", _params, socket) do
    socket = assign(socket, :oauth_status, :starting)
    send(self(), :do_start_oauth)
    {:noreply, socket}
  end

  def handle_event("check_oauth", _params, socket) do
    send(self(), :do_check_oauth)
    {:noreply, socket}
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

  # Launch
  def handle_event("run_launch", _params, socket) do
    send(self(), :do_launch)
    {:noreply, socket}
  end

  # Finish
  def handle_event("finish", _params, socket) do
    send(self(), :do_finish)
    {:noreply, socket}
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

  def handle_info(:do_check_openclaw, socket) do
    case Installer.check_openclaw() do
      {:ok, version} ->
        State.merge(%{install_done: true, install_version: version})

        {:noreply,
         assign(socket, install_done: true, install_version: version, install_status: :installed)}

      :not_installed ->
        {:noreply, assign(socket, install_status: :not_installed)}
    end
  end

  def handle_info(:do_install_openclaw, socket) do
    case Installer.install_openclaw() do
      {:ok, version} ->
        State.merge(%{install_done: true, install_version: version})

        {:noreply,
         assign(socket, install_done: true, install_version: version, install_status: :installed)}

      {:error, _msg} ->
        {:noreply, assign(socket, install_status: :failed)}
    end
  end

  def handle_info(:do_start_oauth, socket) do
    {verifier, challenge} = OAuth.generate_pkce()
    state_param = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    url = OAuth.build_auth_url(state_param, challenge)

    State.put(:oauth_flow, %{verifier: verifier, state: state_param})

    {:noreply, assign(socket, oauth_url: url, oauth_status: :waiting)}
  end

  def handle_info(:do_check_oauth, socket) do
    state = State.get()

    if OAuth.connected?(state.oauth_tokens) do
      {:noreply, assign(socket, oauth_connected: true, oauth_status: :connected)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:oauth_complete, tokens}, socket) do
    State.put(:oauth_tokens, tokens)

    {:noreply, assign(socket, oauth_connected: true, oauth_status: :connected, oauth_url: nil)}
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

  def handle_info(:do_launch, socket) do
    socket =
      launch_step(socket, :configure, "Configuring...", fn ->
        Launcher.configure(socket.assigns.mode, socket.assigns.tg_token)
      end)

    socket =
      launch_step(socket, :gateway, "Starting gateway...", fn ->
        Launcher.start_gateway()
      end)

    has_telegram = socket.assigns.tg_token != nil

    all_ok =
      socket.assigns.launch_items.configure == :pass &&
        socket.assigns.launch_items.gateway == :pass

    socket =
      if has_telegram && all_ok do
        launch_pairing(socket)
      else
        update_launch_item(socket, :pairing, :pass, "Skipped")
      end

    socket =
      launch_step(socket, :health, "Verifying...", fn ->
        Launcher.health_check()
      end)

    items = socket.assigns.launch_items
    all_pass = Enum.all?(Map.values(items), &(&1 == :pass))
    State.merge(%{
      launch_done: true,
      verify_passed: all_pass,
      launch_items: socket.assigns.launch_items,
      launch_messages: socket.assigns.launch_messages
    })

    {:noreply, assign(socket, launch_done: true, verify_passed: all_pass)}
  end

  def handle_info(:do_finish, socket) do
    state = State.get()
    {:ok, _receipt} = Launcher.write_receipt(state)

    # Mark OOBE as complete
    path = Application.get_env(:clawrig, :oobe_marker, "/var/lib/clawrig/.oobe-complete")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

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
      install: "Install OpenClaw",
      oauth: "OpenAI",
      telegram: "Optional Telegram",
      launch: "Launch",
      receipt: "Complete"
    }[step] || ""
  end

  def can_next?(assigns) do
    case assigns.step do
      :preflight -> assigns.preflight_done
      :install -> assigns.install_done
      :oauth -> assigns.oauth_connected
      :telegram -> true
      :launch -> assigns.launch_done
      :receipt -> true
    end
  end

  def at_start?(step), do: step == :preflight
  def at_end?(step), do: step == :receipt

  def next_label(step, assigns) do
    if step == :telegram && !assigns.tg_chat_id, do: "Skip", else: "Continue"
  end

  defp launch_step(socket, key, running_msg, func) do
    socket = update_launch_item(socket, key, :running, running_msg)

    case func.() do
      :ok ->
        update_launch_item(socket, key, :pass, pass_label(key))

      {:error, msg} ->
        update_launch_item(socket, key, :fail, msg)
    end
  end

  defp launch_pairing(socket) do
    socket = update_launch_item(socket, :pairing, :running, "Pairing Telegram...")

    result =
      Enum.reduce_while(1..24, false, fn _, _acc ->
        Process.sleep(2500)

        case Launcher.check_pairing() do
          {:ok, [first | _]} ->
            code = first["code"]

            case Launcher.approve_pairing(code) do
              :ok -> {:halt, true}
              _ -> {:cont, false}
            end

          _ ->
            {:cont, false}
        end
      end)

    if result do
      update_launch_item(socket, :pairing, :pass, "Telegram paired")
    else
      update_launch_item(socket, :pairing, :fail, "Pairing timed out")
    end
  end

  defp update_launch_item(socket, key, status, message) do
    items = Map.put(socket.assigns.launch_items, key, status)
    messages = Map.put(socket.assigns.launch_messages, key, message)
    assign(socket, launch_items: items, launch_messages: messages)
  end

  defp pass_label(:configure), do: "Configured"
  defp pass_label(:gateway), do: "Gateway running"
  defp pass_label(:pairing), do: "Telegram paired"
  defp pass_label(:health), do: "All systems go"

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

  def install_title(:installed), do: "Installed"
  def install_title(:checking), do: "OpenClaw"
  def install_title(:installing), do: "OpenClaw"
  def install_title(:failed), do: "OpenClaw"
  def install_title(_), do: "OpenClaw"

  def install_desc(:installed, version) when is_binary(version), do: "v#{version}"
  def install_desc(:installed, _), do: "Installed"
  def install_desc(:checking, _), do: "Checking..."
  def install_desc(:installing, _), do: "Installing..."
  def install_desc(:failed, _), do: "Installation failed. Tap to retry."
  def install_desc(_, _), do: "Tap to install the runtime"

  def oauth_desc(_status, true), do: "OpenAI account linked."
  def oauth_desc(:starting, _), do: "Preparing sign-in..."
  def oauth_desc(:waiting, _), do: "Complete sign-in in the popup..."
  def oauth_desc(_, _), do: "Sign in to connect your account."

  def launch_title_class(true, true), do: "pass"
  def launch_title_class(true, false), do: "fail"
  def launch_title_class(_, _), do: ""

  def launch_title(true, true), do: "OpenClaw is running"
  def launch_title(true, false), do: "Needs attention"
  def launch_title(_, _), do: "Launching OpenClaw"

  def launch_desc(true, true), do: "Everything is up and operational."
  def launch_desc(true, false), do: "Some steps had issues. You can retry or continue."
  def launch_desc(_, _), do: "Setting everything up..."

  # Launch item component
  attr :key, :atom, required: true
  attr :status, :atom, required: true
  attr :label, :string, required: true

  def launch_item(assigns) do
    ~H"""
    <div class="launch-item">
      <div class="launch-icon-wrap">
        <div :if={@status == :running} class="launch-spinner"></div>
        <svg :if={@status == :pass} class="launch-ok animate" viewBox="0 0 36 36">
          <circle class="launch-ok-circle" cx="18" cy="18" r="16" fill="none" />
          <path class="launch-ok-mark" fill="none" d="M11 19l4 4 10-10" />
        </svg>
        <svg :if={@status == :fail} class="launch-fail animate" viewBox="0 0 36 36">
          <circle class="launch-fail-circle" cx="18" cy="18" r="16" fill="none" />
          <path class="launch-fail-x" fill="none" d="M13 13l10 10M23 13l-10 10" />
        </svg>
        <div :if={@status == :pending} class="launch-pending"></div>
      </div>
      <span class={["launch-label", launch_label_class(@status)]}>
        {@label}
      </span>
    </div>
    """
  end

  defp launch_label_class(:pass), do: "pass"
  defp launch_label_class(:fail), do: "fail"
  defp launch_label_class(_), do: ""
end
