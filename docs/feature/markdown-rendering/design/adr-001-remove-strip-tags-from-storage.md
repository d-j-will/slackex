# ADR-001: Remove strip_tags from Message Storage Pipeline

## Status

Proposed

## Context

Messages in Slackex are stored through 7 code paths (channel send, DM send, edit, thread reply, DM request accept, ChannelServer real-time send, ChannelServer validation). All paths call `HtmlSanitizeEx.strip_tags/1` before storing content. This function:

1. Strips any HTML tags from the input
2. **Encodes special characters**: `>` becomes `&gt;`, `<` becomes `&lt;`, `&` becomes `&amp;`, `"` becomes `&quot;`, `'` becomes `&#39;`

This encoding destroys markdown syntax -- blockquotes use `>`, code blocks may contain `<` and `&`. To compensate, `Markdown.to_html/1` includes `unescape_html/1` which reverses the encoding before Earmark parses markdown. This is a design smell: we encode at storage then immediately decode at render.

The original purpose of `strip_tags` was XSS prevention, but XSS is already handled at render time by two independent mechanisms:
- When markdown is enabled: `Slackex.Markdown.Scrubber` strips unsafe HTML from Earmark output
- When markdown is disabled: HEEx auto-escaping prevents any HTML from rendering as markup

`strip_tags` at storage time provides no unique security value while actively degrading markdown rendering and FTS quality (encoded entities in `search_content`).

## Decision

Remove `HtmlSanitizeEx.strip_tags/1` from all 7 message storage paths. Store raw user input (after length/emptiness validation only). Rely on render-time sanitization for XSS prevention.

## Alternatives Considered

### Alternative 1: Keep strip_tags, improve unescape_html

Continue encoding at storage, expand `unescape_html` to handle all HTML entities. Rejected because:
- Maintains the encode/decode round-trip anti-pattern
- `search_content` still contains encoded entities, degrading FTS quality
- Any new entity encoding by `strip_tags` requires a corresponding decode update -- fragile coupling
- Does not address the root cause

### Alternative 2: Replace strip_tags with a selective sanitizer

Use a custom sanitizer that strips tags but does not encode special characters. Rejected because:
- Requires writing and maintaining a custom sanitizer
- Still mutates user input before storage for no security benefit (render-time sanitization is sufficient)
- Adds complexity where removal of code is the simpler solution

### Alternative 3: Move markdown parsing to storage time (store HTML)

Parse markdown at write time, store the resulting HTML. Rejected because:
- Cloak-encrypted content would be HTML, not the user's original markdown
- Editing requires reverse-parsing HTML back to markdown (lossy)
- Changing the markdown parser or scrubber rules requires re-processing all stored messages
- `search_content` would contain HTML tags, degrading FTS
- Violates the principle of storing the user's canonical input

## Consequences

### Positive

- Eliminates the encode/decode round-trip (`strip_tags` + `unescape_html`)
- `search_content` stores clean plaintext, improving FTS query accuracy
- Markdown syntax (`>`, `<`, `&`) is preserved in storage and renders correctly
- Simpler codebase: removing code from 7 locations
- Content stored is the user's actual input -- no lossy transformation

### Negative

- Existing messages in the database still have HTML-encoded entities; a backfill migration is needed (see ADR-003)
- Raw content in the database includes any HTML the user typed (e.g., `<script>alert(1)</script>`); security depends entirely on render-time sanitization
- If both the Scrubber AND HEEx auto-escaping are somehow bypassed (e.g., a future code path uses `raw()` without the Scrubber), stored XSS payloads could execute. Mitigated by: feature flag kill switch, code review discipline, the Scrubber being a compile-time module that cannot be accidentally skipped by Earmark output
