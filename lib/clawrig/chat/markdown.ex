defmodule Clawrig.Chat.Markdown do
  @moduledoc false

  @doc """
  Converts markdown text to sanitized HTML safe for Phoenix rendering.
  Returns a Phoenix.HTML.safe tuple.
  """
  def render(nil), do: {:safe, ""}
  def render(""), do: {:safe, ""}

  def render(text) when is_binary(text) do
    case MDEx.to_html(text, extension: [table: true, strikethrough: true, autolink: true]) do
      {:ok, html} ->
        {:safe, html}

      {:error, _reason} ->
        {:safe, Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()}
    end
  end
end
