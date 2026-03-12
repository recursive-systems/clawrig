defmodule ClawrigWeb.ChatLive do
  use ClawrigWeb, :live_view

  alias Clawrig.Chat.Markdown
  alias Clawrig.Gateway

  @impl true
  def mount(_params, _session, socket) do
    operator = Gateway.operator_module()
    session_key = Gateway.session_key()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Clawrig.PubSub, Gateway.operator_topic())
      Phoenix.PubSub.subscribe(Clawrig.PubSub, Gateway.chat_topic(session_key))
      send(self(), :load_history)
    end

    socket =
      socket
      |> assign(:page_title, "ClawRig Chat")
      |> assign(:version, read_version())
      |> assign(:session_key, session_key)
      |> assign(:operator_module, operator)
      |> assign(:operator_status, safe_status(operator))
      |> assign(:operator_detail, %{})
      |> assign(:run_state, :idle)
      |> assign(:active_run_id, nil)
      |> assign(:chat_error, nil)
      |> assign(:pairing_busy, false)
      |> assign(:message_lookup, %{})
      |> assign(:active_assistant_message_id, nil)
      |> assign(:assistant_message_ids_by_run, %{})
      |> stream_configure(:messages, dom_id: &message_dom_id/1)
      |> stream(:messages, [])

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_history, socket) do
    _ = socket.assigns.operator_module.history(socket.assigns.session_key)
    {:noreply, socket}
  end

  def handle_info({:pair_result, :ok}, socket) do
    {:noreply,
     socket
     |> assign(:pairing_busy, false)
     |> assign(:chat_error, nil)}
  end

  def handle_info({:pair_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:pairing_busy, false)
     |> assign(:chat_error, to_string(reason))}
  end

  def handle_info({:operator_status, status, detail}, socket) do
    socket =
      socket
      |> assign(:operator_status, status)
      |> assign(:operator_detail, detail || %{})
      |> assign(:pairing_busy, false)

    socket =
      if status == :connected and socket.assigns.operator_status != :connected do
        _ = socket.assigns.operator_module.history(socket.assigns.session_key)
        socket
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:chat_history, session_key, messages, _meta},
        %{assigns: %{session_key: session_key}} = socket
      ) do
    message_lookup =
      messages
      |> Enum.map(&ensure_item_defaults/1)
      |> Enum.filter(&displayable_item?/1)
      |> Map.new(&{item_id(&1), &1})

    socket =
      socket
      |> assign(:message_lookup, message_lookup)
      |> assign(:chat_error, nil)
      |> assign(
        :run_state,
        if(socket.assigns.run_state == :aborting, do: :idle, else: socket.assigns.run_state)
      )
      |> stream(:messages, Map.values(message_lookup), reset: true)

    {:noreply, socket}
  end

  def handle_info(
        {:chat_delta, session_key, run_id, chunk},
        %{assigns: %{session_key: session_key}} = socket
      ) do
    {socket, _id} = append_assistant_delta(socket, run_id, chunk)
    {:noreply, socket}
  end

  def handle_info(
        {:chat_done, session_key, run_id, message},
        %{assigns: %{session_key: session_key}} = socket
      ) do
    message = ensure_item_defaults(message)

    has_active_message =
      (run_id && socket.assigns.assistant_message_ids_by_run[run_id]) ||
        socket.assigns.active_assistant_message_id

    cond do
      message[:role] in ["user", "toolResult"] ->
        {:noreply, socket}

      has_active_message ->
        socket = finalize_assistant_message(socket, run_id, message, "done")
        {:noreply, socket}

      socket.assigns.run_state == :idle ->
        # Duplicate completion event — already finalized, skip
        {:noreply, socket}

      true ->
        socket = finalize_assistant_message(socket, run_id, message, "done")
        {:noreply, socket}
    end
  end

  def handle_info(
        {:chat_aborted, session_key, run_id},
        %{assigns: %{session_key: session_key}} = socket
      ) do
    socket =
      socket
      |> mark_run_complete(run_id, "stopped")
      |> assign(:run_state, :idle)
      |> assign(:active_run_id, nil)

    {:noreply, socket}
  end

  def handle_info({:chat_approval_requested, approval}, socket) do
    item =
      approval
      |> ensure_item_defaults()
      |> Map.put(:inserted_at, System.system_time(:second))

    socket =
      socket
      |> put_item(item)
      |> assign(:run_state, :idle)
      |> assign(:chat_error, nil)

    {:noreply, socket}
  end

  def handle_info({:chat_approval_resolved, approval_id, decision}, socket) do
    socket = update_item(socket, approval_id, fn item -> Map.put(item, :status, decision) end)
    {:noreply, socket}
  end

  def handle_info({:chat_error, _scope, reason}, socket) do
    socket =
      socket
      |> assign(:chat_error, to_string(reason))
      |> assign(:run_state, :idle)
      |> assign(:active_run_id, nil)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_submit", %{"text" => text}, socket) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.operator_status != :connected ->
        {:noreply, assign(socket, :chat_error, "Chat is not connected to the Gateway yet.")}

      socket.assigns.run_state in [:streaming, :aborting] ->
        {:noreply, socket}

      true ->
        user_message = base_message("user", text)

        assistant_placeholder =
          base_message("assistant", "", %{streaming: true, status: "streaming"})

        socket =
          socket
          |> put_item(user_message)
          |> put_item(assistant_placeholder)
          |> assign(:chat_error, nil)
          |> assign(:run_state, :streaming)
          |> assign(:active_assistant_message_id, item_id(assistant_placeholder))
          |> assign(:active_run_id, nil)

        case socket.assigns.operator_module.send(socket.assigns.session_key, text) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            system_note =
              base_message(
                "system",
                "The Gateway rejected that message: #{to_string(reason)}",
                %{status: "error"}
              )

            {:noreply,
             socket
             |> put_item(system_note)
             |> assign(:chat_error, to_string(reason))
             |> assign(:run_state, :idle)
             |> assign(:active_assistant_message_id, nil)}
        end
    end
  end

  def handle_event("chat_abort", _params, %{assigns: %{run_state: :streaming}} = socket) do
    _ =
      socket.assigns.operator_module.abort(
        socket.assigns.session_key,
        socket.assigns.active_run_id
      )

    {:noreply, assign(socket, :run_state, :aborting)}
  end

  def handle_event("chat_abort", _params, socket), do: {:noreply, socket}

  def handle_event("chat_pair", _params, socket) do
    socket = assign(socket, :pairing_busy, true)
    live_view = self()
    operator = socket.assigns.operator_module

    Task.start(fn ->
      result =
        try do
          operator.pair_local_admin()
        catch
          :exit, reason -> {:error, Exception.format_exit(reason)}
        end

      send(live_view, {:pair_result, result})
    end)

    {:noreply, socket}
  end

  def handle_event(
        "approval_decide",
        %{"approval_id" => approval_id, "decision" => decision},
        socket
      ) do
    _ = socket.assigns.operator_module.resolve_approval(approval_id, decision)

    {:noreply,
     update_item(socket, approval_id, fn item -> Map.put(item, :status, "#{decision}-pending") end)}
  end

  defp append_assistant_delta(socket, run_id, chunk) do
    message_id =
      cond do
        run_id && socket.assigns.assistant_message_ids_by_run[run_id] ->
          socket.assigns.assistant_message_ids_by_run[run_id]

        socket.assigns.active_assistant_message_id ->
          socket.assigns.active_assistant_message_id

        true ->
          nil
      end

    {socket, message_id} =
      if message_id do
        {socket, message_id}
      else
        placeholder =
          base_message("assistant", "", %{streaming: true, status: "streaming", run_id: run_id})

        socket = put_item(socket, placeholder)
        {socket, item_id(placeholder)}
      end

    socket =
      socket
      |> update_item(message_id, fn item ->
        item
        |> Map.put(:content, (item[:content] || "") <> (chunk || ""))
        |> Map.put(:streaming, true)
        |> Map.put(:status, "streaming")
        |> Map.put(:run_id, run_id || item[:run_id])
      end)
      |> assign(:run_state, :streaming)
      |> assign(:active_run_id, run_id || socket.assigns.active_run_id)
      |> assign(:active_assistant_message_id, message_id)
      |> assign(
        :assistant_message_ids_by_run,
        maybe_index_run(socket.assigns.assistant_message_ids_by_run, run_id, message_id)
      )

    {socket, message_id}
  end

  defp finalize_assistant_message(socket, run_id, message, status) do
    {socket, message_id} = append_assistant_delta(socket, run_id, "")

    # Prefer the streamed content if the completion message has no content
    existing = Map.get(socket.assigns.message_lookup, message_id, %{})
    incoming = ensure_item_defaults(message)

    content =
      if String.trim(incoming[:content] || "") != "" do
        incoming[:content]
      else
        existing[:content] || ""
      end

    normalized =
      incoming
      |> Map.put(:id, message_id)
      |> Map.put(:content, content)
      |> Map.put(:run_id, run_id || message[:run_id])
      |> Map.put(:status, status)
      |> Map.put(:streaming, false)

    socket
    |> put_item(normalized)
    |> assign(:run_state, :idle)
    |> assign(:active_run_id, nil)
    |> assign(:active_assistant_message_id, nil)
  end

  defp mark_run_complete(socket, run_id, status) do
    message_id =
      socket.assigns.assistant_message_ids_by_run[run_id] ||
        socket.assigns.active_assistant_message_id

    if message_id do
      update_item(socket, message_id, fn item ->
        item
        |> Map.put(:streaming, false)
        |> Map.put(:status, status)
      end)
    else
      socket
    end
  end

  defp put_item(socket, item) do
    item = ensure_item_defaults(item)
    id = item_id(item)

    if displayable_item?(item) do
      socket
      |> assign(:message_lookup, Map.put(socket.assigns.message_lookup, id, item))
      |> stream_insert(:messages, item)
    else
      delete_item(socket, id)
    end
  end

  defp update_item(socket, id, fun) do
    case Map.fetch(socket.assigns.message_lookup, id) do
      {:ok, item} ->
        updated = item |> fun.() |> ensure_item_defaults()

        if displayable_item?(updated) do
          socket
          |> assign(:message_lookup, Map.put(socket.assigns.message_lookup, id, updated))
          |> stream_insert(:messages, updated)
        else
          delete_item(socket, id)
        end

      :error ->
        socket
    end
  end

  defp delete_item(socket, id) do
    case Map.pop(socket.assigns.message_lookup, id) do
      {nil, _lookup} ->
        socket

      {item, lookup} ->
        socket
        |> assign(:message_lookup, lookup)
        |> stream_delete(:messages, item)
    end
  end

  defp ensure_item_defaults(item) do
    item
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.put_new(:id, unique_id("chat"))
    |> Map.put_new(:kind, :message)
    |> Map.put_new(:role, "assistant")
    |> Map.put_new(:content, "")
    |> Map.put_new(:streaming, false)
    |> Map.put_new(:status, "done")
    |> maybe_render_markdown()
  end

  defp maybe_render_markdown(%{streaming: false, content: content} = item)
       when content != "" do
    Map.put(item, :rendered_html, Markdown.render(content))
  end

  defp maybe_render_markdown(item), do: Map.put_new(item, :rendered_html, nil)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("id"), do: :id
  defp normalize_key("kind"), do: :kind
  defp normalize_key("role"), do: :role
  defp normalize_key("content"), do: :content
  defp normalize_key("streaming"), do: :streaming
  defp normalize_key("status"), do: :status
  defp normalize_key("run_id"), do: :run_id
  defp normalize_key("runId"), do: :run_id
  defp normalize_key("title"), do: :title
  defp normalize_key("detail"), do: :detail
  defp normalize_key(other), do: other

  defp item_id(item), do: item[:id] || item["id"]

  defp displayable_item?(%{kind: :approval}), do: true

  defp displayable_item?(item) do
    item[:role] != "toolResult" and
      (item[:streaming] ||
         String.trim(item[:content] || "") != "" ||
         item[:status] in ["streaming", "stopped", "error"])
  end

  defp message_dom_id(item), do: "chat-item-#{item_id(item)}"

  defp maybe_index_run(index, nil, _message_id), do: index
  defp maybe_index_run(index, run_id, message_id), do: Map.put(index, run_id, message_id)

  defp base_message(role, content, attrs \\ %{}) do
    Map.merge(
      %{
        id: unique_id(role),
        kind: :message,
        role: role,
        content: content,
        streaming: false,
        status: "done"
      },
      attrs
    )
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp safe_status(operator) do
    operator.status()
  rescue
    _ -> :unavailable
  end

  defp read_version do
    case File.read("/opt/clawrig/VERSION") do
      {:ok, content} -> String.trim(content)
      _ -> "dev"
    end
  end

  defp nav_class(true), do: "dash-tab active"
  defp nav_class(false), do: "dash-tab"

  defp role_label("assistant"), do: "Assistant"
  defp role_label("system"), do: "System"
  defp role_label(_), do: "You"

  defp operator_label(:connected), do: "Connected"
  defp operator_label(:connecting), do: "Connecting"
  defp operator_label(:unpaired), do: "Pairing Needed"
  defp operator_label(_), do: "Unavailable"

  defp blocked_copy(:unavailable, detail) do
    detail[:detail] || detail["detail"] ||
      "ClawRig is still waiting for the local Gateway to come up."
  end

  defp blocked_copy(:unpaired, detail) do
    detail[:detail] || detail["detail"] ||
      "Approve this dashboard with the local Gateway to unlock chat for the main agent."
  end
end
