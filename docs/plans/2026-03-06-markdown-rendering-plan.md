# Markdown Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a reusable `Slackex.Markdown` module that converts markdown to sanitized HTML, and integrate it into the summary modal and chat messages.

**Architecture:** Earmark parses markdown to HTML, a custom HtmlSanitizeEx scrubber allowlists safe tags, and `Phoenix.HTML.raw/1` wraps the result for HEEx templates. Rendering happens at the view layer only.

**Tech Stack:** Earmark, HtmlSanitizeEx (existing), Phoenix.HTML

---

### Task 1: Add Earmark dependency

**Files:**
- Modify: `mix.exs`

**Step 1: Add earmark to deps**

In `mix.exs`, add to the `deps` function:

```elixir
{:earmark, "~> 1.4"},
```

**Step 2: Fetch deps**

Run: `mix deps.get`
Expected: earmark fetched successfully

**Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add earmark for markdown rendering"
```

---

### Task 2: Create the custom scrubber module

**Files:**
- Create: `lib/slackex/markdown/scrubber.ex`
- Test: `test/slackex/markdown/markdown_test.exs`

**Step 1: Write failing tests for sanitization**

Create `test/slackex/markdown/markdown_test.exs`:

```elixir
defmodule Slackex.MarkdownTest do
  use ExUnit.Case, async: true

  alias Slackex.Markdown

  describe "to_html/1" do
    test "renders bold text" do
      assert safe_to_string(Markdown.to_html("**bold**")) =~ "<strong>bold</strong>"
    end

    test "renders italic text" do
      assert safe_to_string(Markdown.to_html("*italic*")) =~ "<em>italic</em>"
    end

    test "renders headings" do
      assert safe_to_string(Markdown.to_html("# Heading")) =~ "<h1>"
    end

    test "renders unordered lists" do
      html = safe_to_string(Markdown.to_html("- item one\n- item two"))
      assert html =~ "<ul>"
      assert html =~ "<li>"
    end

    test "renders ordered lists" do
      html = safe_to_string(Markdown.to_html("1. first\n2. second"))
      assert html =~ "<ol>"
      assert html =~ "<li>"
    end

    test "renders code blocks" do
      html = safe_to_string(Markdown.to_html("```\ncode here\n```"))
      assert html =~ "<pre>"
      assert html =~ "<code>"
    end

    test "renders inline code" do
      assert safe_to_string(Markdown.to_html("use `mix test`")) =~ "<code"
    end

    test "renders links with safe attributes" do
      html = safe_to_string(Markdown.to_html("[click](https://example.com)"))
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ ~s(target="_blank")
    end

    test "renders blockquotes" do
      assert safe_to_string(Markdown.to_html("> quoted")) =~ "<blockquote>"
    end

    test "renders tables" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """
      html = safe_to_string(Markdown.to_html(md))
      assert html =~ "<table>"
      assert html =~ "<td>"
    end

    test "renders strikethrough" do
      assert safe_to_string(Markdown.to_html("~~deleted~~")) =~ "<del>"
    end

    test "renders plain text without markdown" do
      html = safe_to_string(Markdown.to_html("just plain text"))
      assert html =~ "just plain text"
    end

    test "handles empty string" do
      assert safe_to_string(Markdown.to_html("")) == ""
    end

    test "handles nil" do
      assert safe_to_string(Markdown.to_html(nil)) == ""
    end
  end

  describe "XSS sanitization" do
    test "strips script tags" do
      html = safe_to_string(Markdown.to_html("<script>alert('xss')</script>"))
      refute html =~ "<script"
      refute html =~ "alert"
    end

    test "strips event handlers" do
      html = safe_to_string(Markdown.to_html(~s(<div onclick="alert('xss')">click</div>)))
      refute html =~ "onclick"
      refute html =~ "alert"
    end

    test "strips javascript: URLs in links" do
      html = safe_to_string(Markdown.to_html(~s([click](javascript:alert('xss')))))
      refute html =~ "javascript:"
    end

    test "strips iframe tags" do
      html = safe_to_string(Markdown.to_html(~s(<iframe src="evil.com"></iframe>)))
      refute html =~ "<iframe"
    end

    test "strips style tags" do
      html = safe_to_string(Markdown.to_html("<style>body{display:none}</style>"))
      refute html =~ "<style"
    end

    test "strips img tags" do
      html = safe_to_string(Markdown.to_html(~s(<img src="x" onerror="alert(1)">)))
      refute html =~ "<img"
      refute html =~ "onerror"
    end
  end

  defp safe_to_string({:safe, html}), do: html
  defp safe_to_string(other), do: to_string(other)
end
```

**Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/markdown/markdown_test.exs`
Expected: compilation error -- Slackex.Markdown not found

**Step 3: Create the scrubber module**

Create `lib/slackex/markdown/scrubber.ex`:

```elixir
defmodule Slackex.Markdown.Scrubber do
  @moduledoc """
  HTML sanitization scrubber for markdown-rendered content.

  Allowlists safe block and inline elements while stripping
  dangerous tags, attributes, and URI schemes.

  To modify allowed tags, edit the `allow_tag_with_*` declarations below.
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  # Strip comments and CDATA
  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()

  # Block elements
  Meta.allow_tag_with_these_attributes("p", [])
  Meta.allow_tag_with_these_attributes("h1", [])
  Meta.allow_tag_with_these_attributes("h2", [])
  Meta.allow_tag_with_these_attributes("h3", [])
  Meta.allow_tag_with_these_attributes("h4", [])
  Meta.allow_tag_with_these_attributes("h5", [])
  Meta.allow_tag_with_these_attributes("h6", [])
  Meta.allow_tag_with_these_attributes("blockquote", [])
  Meta.allow_tag_with_these_attributes("pre", ["class"])
  Meta.allow_tag_with_these_attributes("code", ["class"])
  Meta.allow_tag_with_these_attributes("hr", [])
  Meta.allow_tag_with_these_attributes("br", [])
  Meta.allow_tag_with_these_attributes("ul", [])
  Meta.allow_tag_with_these_attributes("ol", [])
  Meta.allow_tag_with_these_attributes("li", [])

  # Table elements
  Meta.allow_tag_with_these_attributes("table", [])
  Meta.allow_tag_with_these_attributes("thead", [])
  Meta.allow_tag_with_these_attributes("tbody", [])
  Meta.allow_tag_with_these_attributes("tr", [])
  Meta.allow_tag_with_these_attributes("th", [])
  Meta.allow_tag_with_these_attributes("td", [])

  # Inline elements
  Meta.allow_tag_with_these_attributes("strong", [])
  Meta.allow_tag_with_these_attributes("em", [])
  Meta.allow_tag_with_these_attributes("del", [])

  # Links -- only safe URI schemes
  Meta.allow_tag_with_uri_attributes("a", ["href"], ["https", "http", "mailto"])
  Meta.allow_tag_with_these_attributes("a", ["rel", "target"])

  # Strip everything else
  Meta.strip_everything_not_covered()
end
```

**Step 4: Commit**

```bash
git add lib/slackex/markdown/scrubber.ex test/slackex/markdown/markdown_test.exs
git commit -m "feat(markdown): add custom HTML scrubber with safe tag allowlist"
```

---

### Task 3: Create the Slackex.Markdown module

**Files:**
- Create: `lib/slackex/markdown.ex`

**Step 1: Implement the module**

Create `lib/slackex/markdown.ex`:

```elixir
defmodule Slackex.Markdown do
  @moduledoc """
  Converts markdown strings to sanitized HTML safe for rendering.

  Uses Earmark for parsing and a custom scrubber for XSS prevention.
  Returns `{:safe, html}` tuples for direct use in HEEx templates.

  ## Usage

      {Slackex.Markdown.to_html(@content)}
  """

  @doc """
  Converts a markdown string to sanitized HTML.

  Returns a Phoenix.HTML safe tuple `{:safe, html}` that can be
  directly interpolated in HEEx templates.

  Returns `{:safe, ""}` for nil or empty input.
  """
  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(compact_output: true)
    |> HtmlSanitizeEx.Scrubber.scrub(Slackex.Markdown.Scrubber)
    |> add_link_attributes()
    |> Phoenix.HTML.raw()
  end

  defp add_link_attributes(html) do
    String.replace(html, "<a ", ~s(<a rel="noopener noreferrer" target="_blank" ))
  end
end
```

**Step 2: Run all markdown tests**

Run: `mix test test/slackex/markdown/markdown_test.exs`
Expected: All tests pass

**Step 3: Run format and credo**

Run: `mix format && mix credo`
Expected: No issues

**Step 4: Commit**

```bash
git add lib/slackex/markdown.ex
git commit -m "feat(markdown): add Markdown.to_html/1 with Earmark + sanitization"
```

---

### Task 4: Integrate into summary modal

**Files:**
- Modify: `lib/slackex_web/live/chat_live/summary_modal.ex:99,103`

**Step 1: Replace raw text with markdown rendering**

In `summary_modal.ex`, change line 99 from:
```heex
<div class="prose prose-sm max-w-none whitespace-pre-wrap">{@summary_text}</div>
```
to:
```heex
<div class="prose prose-sm max-w-none">{Slackex.Markdown.to_html(@summary_text)}</div>
```

Do the same for line 103 (the `:complete` state).

Note: Remove `whitespace-pre-wrap` since markdown generates proper `<p>` tags.

**Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile

**Step 3: Commit**

```bash
git add lib/slackex_web/live/chat_live/summary_modal.ex
git commit -m "feat(markdown): render markdown in channel summary modal"
```

---

### Task 5: Integrate into chat messages

**Files:**
- Modify: `lib/slackex_web/components/chat_components.ex:166-173,214-215`

**Step 1: Update rendered_content to use Markdown.to_html**

In `chat_components.ex`, change lines 166-173 from:
```elixir
|> assign(
  :rendered_content,
  if assigns.link_previews_enabled do
    URLExtractor.linkify(Map.get(message, :content, ""))
  else
    Map.get(message, :content, "")
  end
)
```
to:
```elixir
|> assign(
  :rendered_content,
  Map.get(message, :content, "") |> Slackex.Markdown.to_html()
)
```

Note: Markdown link rendering supersedes URLExtractor.linkify for now. Links in markdown `[text](url)` will be rendered. Plain URLs in text won't auto-link -- this matches standard markdown behavior. If auto-linking plain URLs is needed later, add an Earmark plugin.

**Step 2: Update the template markup**

Change line 214 from:
```heex
<p class="text-sm text-base-content/90 break-words whitespace-pre-wrap">
  {@rendered_content}<span :if={@is_edited} ...>(edited)</span>
</p>
```
to:
```heex
<div class="text-sm text-base-content/90 break-words prose prose-sm max-w-none">
  {@rendered_content}
  <span :if={@is_edited} class="text-xs text-base-content/40 ml-1">(edited)</span>
</div>
```

Note: Changed `<p>` to `<div>` because markdown output contains block elements (`<p>`, `<ul>`, etc.) which can't nest inside `<p>`.

**Step 3: Run full test suite**

Run: `mix test`
Expected: All tests pass

**Step 4: Commit**

```bash
git add lib/slackex_web/components/chat_components.ex
git commit -m "feat(markdown): render markdown in chat messages"
```

---

### Task 6: Final verification and deploy

**Step 1: Run format, credo, dialyzer**

Run: `mix format --check-formatted && mix credo && mix dialyzer`
Expected: All pass

**Step 2: Run full test suite**

Run: `mix test`
Expected: All tests pass (1135+ tests)

**Step 3: Commit design doc**

```bash
git add docs/plans/2026-03-06-markdown-rendering-design.md docs/plans/2026-03-06-markdown-rendering-plan.md
git commit -m "docs: add markdown rendering design and implementation plan"
```

**Step 4: Deploy**

Run: `/deploy`
