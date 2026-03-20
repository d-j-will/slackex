defmodule Slackex.MarkdownTest do
  use ExUnit.Case, async: true

  alias Slackex.Markdown

  describe "to_html/1 rendering" do
    test "renders bold text" do
      assert html("**bold**") =~ "<strong>bold</strong>"
    end

    test "renders italic text" do
      assert html("*italic*") =~ "<em>italic</em>"
    end

    test "renders headings" do
      assert html("# Heading") =~ "<h1>"
      assert html("## Sub") =~ "<h2>"
    end

    test "renders unordered lists" do
      result = html("- item one\n- item two")
      assert result =~ "<ul>"
      assert result =~ "<li>"
    end

    test "renders ordered lists" do
      result = html("1. first\n2. second")
      assert result =~ "<ol>"
      assert result =~ "<li>"
    end

    test "renders code blocks" do
      result = html("```\ncode here\n```")
      assert result =~ "<pre>"
      assert result =~ "<code>"
    end

    test "renders inline code" do
      assert html("use `mix test`") =~ "<code"
    end

    test "renders links with safe attributes" do
      result = html("[click](https://example.com)")
      assert result =~ ~s(href="https://example.com")
      assert result =~ ~s(rel="noopener noreferrer")
      assert result =~ ~s(target="_blank")
    end

    test "renders blockquotes" do
      assert html("> quoted") =~ "<blockquote>"
    end

    test "renders tables" do
      md = "| A | B |\n|---|---|\n| 1 | 2 |"
      result = html(md)
      assert result =~ "<table>"
      assert result =~ "<td>"
    end

    test "renders strikethrough" do
      assert html("~~deleted~~") =~ "<del>"
    end

    test "renders plain text without markdown" do
      assert html("just plain text") =~ "just plain text"
    end

    test "handles empty string" do
      assert Markdown.to_html("") == {:safe, ""}
    end

    test "handles nil" do
      assert Markdown.to_html(nil) == {:safe, ""}
    end
  end

  describe "chat preprocessing (no blank lines between blocks)" do
    test "headings without blank lines parse as separate headings" do
      result = html("# Heading 1\n## Heading 2\n### Heading 3")
      assert result =~ "<h1>"
      assert result =~ "<h2>"
      assert result =~ "<h3>"
    end

    test "list after paragraph parses as list" do
      result = html("some text\n- bullet one\n- bullet two")
      assert result =~ "<ul>"
      assert result =~ "<li>"
      assert result =~ "bullet one"
      assert result =~ "bullet two"
    end

    test "ordered list after paragraph parses as list" do
      result = html("some text\n1. first\n2. second")
      assert result =~ "<ol>"
      assert result =~ "<li>"
    end

    test "consecutive list items stay tight (no <p> wrapping)" do
      result = html("- a\n- b\n- c")
      assert result =~ "<ul>"
      refute result =~ "<li><p>"
      refute result =~ "<li>\n<p>"
    end

    test "blockquote after text parses as blockquote" do
      result = html("some text\n> quoted")
      assert result =~ "<blockquote>"
    end

    test "text after blockquote is not swallowed" do
      result = html("> quoted\nnot quoted")
      assert result =~ "<blockquote>"
      assert result =~ "<p>not quoted</p>"
    end

    test "horizontal rule after text" do
      result = html("some text\n---")
      assert result =~ "<hr"
    end

    test "code fence after text" do
      result = html("some text\n```\ncode\n```")
      assert result =~ "<pre>"
      assert result =~ "<code>"
    end

    test "table after text" do
      result = html("some text\n| A | B |\n|---|---|\n| 1 | 2 |")
      assert result =~ "<table>"
      assert result =~ "<td>"
    end

    test "code fence content is not modified by preprocessor" do
      input =
        "some text\n```\n| not | a | table |\n- not a list\n# not a heading\n```\nafter code"

      result = html(input)
      assert result =~ "<pre>"
      assert result =~ "not a heading"
      refute result =~ "<table>"
      assert result =~ "<p>after code</p>"
    end

    test "code fence with language tag preserves content" do
      input = "text\n```elixir\ndef hello, do: :ok\n```\n| A | B |\n|---|---|\n| 1 | 2 |"
      result = html(input)
      assert result =~ "<code class=\"elixir\">"
      assert result =~ "def hello"
      assert result =~ "<table>"
    end

    test "table rows stay together" do
      result = html("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
      assert result =~ "<table>"
      assert result =~ "3"
      assert result =~ "4"
    end

    test "full chat message with all block types" do
      input = """
      # Title
      ## Subtitle
      Hello **world**
      - item a
      - item b
      1. one
      2. two
      > a quote
      \`code\` here
      ---
      | X | Y |
      |---|---|
      | 1 | 2 |
      [link](https://example.com)
      """

      result = html(input)
      assert result =~ "<h1>"
      assert result =~ "<h2>"
      assert result =~ "<strong>world</strong>"
      assert result =~ "<ul>"
      assert result =~ "<ol>"
      assert result =~ "<blockquote>"
      assert result =~ "<code"
      assert result =~ "<hr"
      assert result =~ "<table>"
      assert result =~ ~s(href="https://example.com")
    end
  end

  describe "raw content rendering (post-backfill storage)" do
    # After the backfill migration, messages are stored raw (no strip_tags).
    # These tests verify that literal markdown characters render correctly.

    test "raw > renders as blockquote" do
      result = html("> This is a quote")
      assert result =~ "<blockquote>"
      assert result =~ "This is a quote"
    end

    test "raw >> renders as nested blockquote" do
      result = html(">> nested quote")
      assert result =~ "<blockquote>"
    end

    test "raw & in text renders as HTML entity" do
      result = html("Tom & Jerry")
      assert result =~ "Tom &amp; Jerry"
    end

    test "full message with raw markdown characters" do
      input = """
      # Title
      ## Subtitle
      Hello **world**
      - item a
      - item b
      > a quote
      `code` here
      [link](https://example.com)
      """

      result = html(input)
      assert result =~ "<h1>"
      assert result =~ "<h2>"
      assert result =~ "<strong>world</strong>"
      assert result =~ "<ul>"
      assert result =~ "<blockquote>"
      assert result =~ "<code"
      assert result =~ ~s(href="https://example.com")
    end

    test "chat-style input (no blank lines) with raw markdown" do
      input = "# Heading\nSome text\n- bullet\n> quote\n`code`"
      result = html(input)
      assert result =~ "<h1>"
      assert result =~ "<ul>"
      assert result =~ "<blockquote>"
      assert result =~ "<code"
    end
  end

  describe "XSS sanitization" do
    test "strips script tags" do
      result = html("<script>alert('xss')</script>")
      refute result =~ "<script"
    end

    test "strips event handlers" do
      result = html(~s[<div onclick="alert('xss')">click</div>])
      refute result =~ "onclick"
      refute result =~ "alert"
    end

    test "strips javascript: URLs in links" do
      result = html(~s{[click](javascript:alert('xss'))})
      refute result =~ "javascript"
    end

    test "strips iframe tags" do
      result = html(~s[<iframe src="evil.com"></iframe>])
      refute result =~ "<iframe"
    end

    test "strips style tags" do
      result = html(~s[<style>body{display: none}</style>])
      refute result =~ "<style"
    end

    test "strips img tags" do
      result = html(~s[<img src="x" onerror="alert(1)">])
      refute result =~ "<img"
      refute result =~ "onerror"
    end
  end

  describe "XSS defense in depth (render-time only)" do
    # These tests document the security model: render-time sanitization via
    # the Scrubber is sufficient for XSS prevention. strip_tags at storage
    # time is defense-in-depth but not required for safety.

    test "script tag is stripped by Markdown.to_html/1" do
      result = html("<script>alert(1)</script>")

      refute result =~ "<script>"
      refute result =~ "<script"
      refute result =~ "</script>"
    end

    test "HEEx auto-escaping prevents script execution for raw content" do
      # When content is NOT processed through Markdown.to_html/1,
      # Phoenix's HEEx templates auto-escape all interpolated values.
      # This test simulates what HEEx does with raw user content.
      malicious_input = "<script>alert(1)</script>"

      {:safe, escaped} = Phoenix.HTML.html_escape(malicious_input)
      escaped_string = IO.iodata_to_binary(escaped)

      refute escaped_string =~ "<script>"
      assert escaped_string =~ "&lt;script&gt;"
      assert escaped_string =~ "&lt;/script&gt;"
    end

    test "img tag with onerror handler is stripped by Scrubber" do
      result = html("<img onerror=alert(1)>")

      refute result =~ "<img"
      refute result =~ "onerror"
      refute result =~ "alert"
    end

    test "raw > character renders as blockquote" do
      result = html("> This should be a blockquote")

      assert result =~ "<blockquote>"
      assert result =~ "This should be a blockquote"
    end

    test "Phoenix.HTML.raw/1 is only used in safe sanitization contexts" do
      # Static analysis: Phoenix.HTML.raw/1 bypasses HEEx auto-escaping,
      # so it must only be called after proper sanitization. This test
      # verifies that raw() usage is confined to known-safe locations.
      lib_path = Path.join(File.cwd!(), "lib")

      raw_usage_files =
        Path.wildcard(Path.join(lib_path, "**/*.{ex,heex}"))
        |> Enum.filter(fn path ->
          content = File.read!(path)

          String.contains?(content, "Phoenix.HTML.raw") or
            Regex.match?(~r/\|>\s*raw\(\)/, content)
        end)
        |> Enum.map(&Path.relative_to(&1, File.cwd!()))
        |> Enum.sort()

      # Phoenix.HTML.raw/1 must only appear in:
      # 1. lib/slackex/markdown.ex -- output of full sanitization pipeline
      # 2. lib/slackex_web/live/chat_live/search_component.ex -- after html_escape + safe mark restoration
      allowed_files =
        [
          "lib/slackex/markdown.ex",
          "lib/slackex_web/live/chat_live/search_component.ex"
        ]
        |> Enum.sort()

      assert raw_usage_files == allowed_files,
             "Phoenix.HTML.raw/1 found in unexpected files: #{inspect(raw_usage_files -- allowed_files)}. " <>
               "raw/1 bypasses HEEx auto-escaping and must only be used after sanitization."
    end
  end

  defp html(markdown) do
    {:safe, result} = Markdown.to_html(markdown)
    result
  end
end
