defmodule Clawrig.Chat.MarkdownTest do
  use ExUnit.Case, async: true

  alias Clawrig.Chat.Markdown

  describe "render/1" do
    test "returns safe empty string for nil and empty" do
      assert {:safe, ""} = Markdown.render(nil)
      assert {:safe, ""} = Markdown.render("")
    end

    test "renders headings" do
      {:safe, html} = Markdown.render("# Hello")
      assert html =~ "<h1>"
      assert html =~ "Hello"
    end

    test "renders lists" do
      {:safe, html} = Markdown.render("- one\n- two\n- three")
      assert html =~ "<ul>"
      assert html =~ "<li>"
    end

    test "renders inline code" do
      {:safe, html} = Markdown.render("use `mix test` to run")
      assert html =~ "<code>"
      assert html =~ "mix test"
    end

    test "renders fenced code blocks" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      {:safe, html} = Markdown.render(md)
      assert html =~ "<pre"
      assert html =~ "<code"
    end

    test "omits raw HTML (script tags)" do
      {:safe, html} = Markdown.render("<script>alert('xss')</script>\n\nhello")
      refute html =~ "<script"
      refute html =~ "alert"
      assert html =~ "hello"
    end

    test "omits raw HTML (iframe tags)" do
      {:safe, html} = Markdown.render("<iframe src=\"evil.com\"></iframe>\n\nsafe text")
      refute html =~ "<iframe"
      assert html =~ "safe text"
    end

    test "renders bold and italic" do
      {:safe, html} = Markdown.render("**bold** and *italic*")
      assert html =~ "<strong>"
      assert html =~ "<em>"
    end

    test "renders links via autolink" do
      {:safe, html} = Markdown.render("visit https://example.com today")
      assert html =~ "<a"
      assert html =~ "https://example.com"
    end

    test "renders tables" do
      md = "| A | B |\n|---|---|\n| 1 | 2 |"
      {:safe, html} = Markdown.render(md)
      assert html =~ "<table>"
    end
  end
end
