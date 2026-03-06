# Markdown Rendering Design

**Date:** 2026-03-06
**Status:** Approved

## Goal

Add a general-purpose markdown rendering module to convert markdown strings to safe HTML for use across the app: AI summaries, chat messages, and future features.

## Approach

Earmark (pure Elixir markdown parser) + HtmlSanitizeEx (already a dependency) with a custom scrubber that allowlists safe tags.

## Module: `Slackex.Markdown`

**Location:** `lib/slackex/markdown.ex`

**Public API:**
- `to_html(markdown_string)` -- returns `{:safe, html_string}` (Phoenix.HTML safe tuple)

**Pipeline:**
1. `Earmark.as_html!/2` -- parse markdown to raw HTML
2. Custom `Slackex.Markdown.Scrubber` -- allowlist safe tags, strip dangerous content
3. `Phoenix.HTML.raw/1` -- wrap for HEEx template rendering

## Scrubber Allowlist

Defined in `Slackex.Markdown.Scrubber` using `HtmlSanitizeEx.Scrubber` DSL. Designed to be easily modified.

**Block elements:** `p`, `h1`-`h6`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`, `hr`, `br`, `table`, `thead`, `tbody`, `tr`, `th`, `td`

**Inline elements:** `strong`, `em`, `del`, `a`, `code`

**Allowed attributes:**
- `a`: `href` (validated, no `javascript:`), with `rel="noopener noreferrer"` and `target="_blank"` enforced
- `code`/`pre`: `class` (for syntax highlighting classes)

**Stripped:** `script`, `iframe`, `style`, `img`, `form`, `input`, all event handler attributes

## Integration Points

1. **Summary modal** (`summary_modal.ex`): replace `{@summary_text}` with `{Slackex.Markdown.to_html(@summary_text)}`
2. **Chat messages** (`chat_components.ex`): replace plain text with `{Slackex.Markdown.to_html(msg.content)}`

## Architecture Decisions

- **Render at view layer, not storage** -- markdown-to-HTML happens in templates. Stored content remains plaintext (encrypted via Cloak). This keeps markdown a pure view concern.
- **Configurable scrubber** -- allowlist lives in a dedicated scrubber module, easy to add/remove tags without touching the main module.
- **No caching initially** -- Earmark is fast for short text. If performance becomes an issue, add ETS caching keyed by content hash.

## Dependencies

- `earmark` (new) -- pure Elixir markdown parser
- `html_sanitize_ex` (existing) -- HTML sanitization

## Testing

- Unit tests for `to_html/1`: headings, bold, italic, lists, code blocks, links, tables
- XSS sanitization: script tags, event handlers, `javascript:` URLs, nested attacks
- Edge cases: empty string, nil, plain text without markdown
