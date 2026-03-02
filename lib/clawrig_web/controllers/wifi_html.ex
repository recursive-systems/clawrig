defmodule ClawrigWeb.WifiHTML do
  use ClawrigWeb, :html

  embed_templates "wifi_html/*"

  attr :signal, :integer, required: true

  def signal_bars(assigns) when is_map(assigns) do
    active = "var(--ink-bright, #fff)"
    inactive = "var(--line, rgba(255,255,255,0.12))"
    s = assigns.signal

    assigns =
      assigns
      |> assign(:active, active)
      |> assign(:inactive, inactive)
      |> assign(:c1, if(s >= 25, do: active, else: inactive))
      |> assign(:c2, if(s >= 50, do: active, else: inactive))
      |> assign(:c3, if(s >= 75, do: active, else: inactive))

    ~H"""
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="18" r="1.5" fill={@active} stroke="none" />
      <path d="M9.17 13.17a5.5 5.5 0 0 1 5.66 0" stroke={@c1} />
      <path d="M6.34 10.34a10 10 0 0 1 11.32 0" stroke={@c2} />
      <path d="M3.28 7.28a14.5 14.5 0 0 1 17.44 0" stroke={@c3} />
    </svg>
    """
  end

  # Keep string-returning version for backward compat with template
  def signal_bars(signal) when is_integer(signal) do
    cond do
      signal >= 75 -> "||||"
      signal >= 50 -> "|||"
      signal >= 25 -> "||"
      true -> "|"
    end
  end
end
