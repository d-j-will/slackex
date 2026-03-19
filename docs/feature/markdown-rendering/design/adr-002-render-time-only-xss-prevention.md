# ADR-002: Render-Time-Only XSS Prevention Strategy

## Status

Proposed

## Context

The current system applies XSS prevention at two points:

1. **Storage time**: `HtmlSanitizeEx.strip_tags/1` encodes HTML entities and removes tags
2. **Render time**: `Slackex.Markdown.Scrubber` (when markdown enabled) or HEEx auto-escaping (when markdown disabled)

This double-protection creates problems: `strip_tags` encoding conflicts with markdown syntax, requiring a compensating `unescape_html` step. The storage-time sanitization provides no unique security value because render-time protection is comprehensive.

Modern web security best practices (OWASP) recommend **output encoding** (render-time) as the primary XSS defense, not input sanitization. Input validation (type, length, format) is complementary, but mutating input for XSS prevention at storage time is not recommended because:
- It is lossy (destroys legitimate characters)
- It creates false confidence (render-time encoding is still needed)
- It does not protect against stored XSS from other input vectors (DB imports, API)

## Decision

Adopt render-time-only XSS prevention. The defense-in-depth model has two layers, both at render time:

| Markdown State | Primary Defense | Mechanism |
|---------------|----------------|-----------|
| Enabled | `Slackex.Markdown.Scrubber` | Allowlist-based: only explicitly permitted tags/attributes pass through |
| Disabled | HEEx auto-escaping | Phoenix default: all interpolated values are HTML-escaped |

Storage-time processing is limited to **validation** (content length 1-4000 chars, non-empty after trim) with no mutation of the content.

## Alternatives Considered

### Alternative 1: Storage-time AND render-time sanitization (current approach)

Keep both layers. Rejected because:
- `strip_tags` encoding destroys markdown syntax
- Compensating `unescape_html` is a maintenance burden
- Storage-time sanitization provides no unique defense (render-time is comprehensive)
- Double sanitization can cause double-encoding bugs

### Alternative 2: CSP-based XSS prevention instead of sanitization

Use Content-Security-Policy headers to prevent inline script execution, eliminating the need for HTML sanitization. Rejected because:
- CSP is an additional layer, not a replacement for output encoding
- Does not prevent HTML injection (e.g., phishing forms rendered in chat)
- The Scrubber provides structural control (only allowed tags render) which CSP cannot replicate
- Could be added as an additional layer in future without architectural changes

## Consequences

### Positive

- Single, clear point of XSS responsibility (render time)
- No lossy transformation of user input
- Markdown syntax preserved through the full pipeline
- Scrubber allowlist is explicit and auditable -- tags/attributes not listed are stripped
- HEEx auto-escaping is a Phoenix framework guarantee, not custom code

### Negative

- Raw HTML is stored in the database; any new render path must use either the Scrubber (via `Markdown.to_html/1`) or HEEx auto-escaping -- never `Phoenix.HTML.raw(content)` without the Scrubber
- Developers must understand that `raw()` bypasses HEEx auto-escaping and must only be used with Scrubber-sanitized output
- Feature flag `:markdown_rendering` serves as a kill switch; disabling it falls back to HEEx auto-escaping which handles raw HTML safely

### Required Mitigations (from review)

- **CI grep check:** A CI step must fail the build if `raw(` appears in any file other than `lib/slackex/markdown.ex`. Since this ADR moves XSS prevention entirely to render time, the `raw()` function becomes the single most dangerous call in the codebase -- any use of it outside `Markdown.to_html/1` bypasses the Scrubber and exposes stored raw content directly to the browser. This check must be automated, not left to code review discipline.
- **Feature flag kill-switch acceptance test:** An acceptance test must verify that toggling `:markdown_rendering` OFF causes the system to fall back to HEEx auto-escaping correctly. Specifically, the test must store a `<script>` payload, disable the flag, render the message, and assert that the script tag is escaped (visible as text, not executed). This validates that the kill switch actually works end-to-end, not just that HEEx escaping works in isolation.
