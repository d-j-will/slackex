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

  defp html(markdown) do
    {:safe, result} = Markdown.to_html(markdown)
    result
  end
end
