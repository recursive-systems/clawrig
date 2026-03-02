defmodule ClawrigWeb.CoreComponents do
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ClawrigWeb.Endpoint,
    router: ClawrigWeb.Router,
    statics: ClawrigWeb.static_paths()

  alias Phoenix.LiveView.JS

  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["flash", "flash-#{@kind}"]}
      {@rest}
    >
      <p :if={@title} class="flash-title">{@title}</p>
      <p>{msg}</p>
    </div>
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector, time: 300)
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector, time: 200)
  end

  attr :title, :string, default: nil, doc: "panel heading"
  attr :back, :boolean, default: false, doc: "show back link to dashboard index"
  slot :actions, doc: "buttons rendered right-aligned in header row"
  slot :inner_block, required: true

  def dash_panel(assigns) do
    ~H"""
    <div class="dash-panel">
      <div :if={@title || @back || @actions != []} class="dash-panel-header">
        <div class="dash-panel-title-row">
          <.link :if={@back} navigate={~p"/"} class="dash-back">&larr; Dashboard</.link>
          <h2 :if={@title}>{@title}</h2>
        </div>
        <div :if={@actions != []} class="dash-panel-actions">
          {render_slot(@actions)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
