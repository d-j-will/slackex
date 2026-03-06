# Link Previews -- Design

## Goal

When a user posts a message containing URLs, render rich inline preview cards (title, description, image, favicon) below the message. Block previews for unsafe or suspicious URLs.

## Architecture

Message sending is never blocked by preview fetching. URLs are extracted from message content at send time, and an Oban worker fetches metadata asynchronously. Results are broadcast via PubSub so all connected users see previews appear in real-time.

```
User sends message
  -> URLs extracted (regex)
  -> Message saved to DB
  -> LinkPreviewWorker enqueued (Oban)
  -> Worker: blocklist check -> Safe Browsing check -> HTTP fetch (2s timeout) -> parse OG tags
  -> link_previews row inserted
  -> PubSub broadcast "link_preview_ready"
  -> All connected LiveViews render preview card below message
```

Feature-flagged behind `:link_previews` (FunWithFlags), disabled by default.

## URL Safety

Multi-layer approach:

1. **Compile-time domain blocklist** -- A MapSet loaded from a text file at compile time, sourced from community blocklists (Steven Black's hosts). Covers porn, spam, gambling. Zero runtime cost for lookups.

2. **Google Safe Browsing API** -- Checks URLs against Google's threat lists (phishing, malware, social engineering). Free tier: 10k lookups/day.

3. **Fetch failure = block** -- Any URL that doesn't respond within 2 seconds, returns an HTTP error, or has SSL issues is treated as suspicious and blocked. Logged at `:warning` level. No retries.

## Security: Prompt Injection & Content Sanitization

URLs and their fetched metadata flow into three downstream systems: display (LiveView), embeddings (pgvector), and LLM summarization. Each is a potential injection surface.

### Threat Model

- **OG tags as injection vector** -- A malicious site could set `og:title` or `og:description` to contain LLM prompt injection payloads. If fed raw into summarization, the LLM could be manipulated.
- **Embedding poisoning** -- Injected text in preview metadata could skew semantic search results.
- **XSS via preview rendering** -- OG tags could contain `<script>` or event handlers.

### Mitigations

| Layer | Mitigation |
|-------|------------|
| Fetch | Strip all HTML tags from OG title/description at parse time. Truncate fields (title: 200 chars, description: 500 chars). Reject non-UTF8. |
| Storage | Preview metadata in its own table, never written to `search_content`. Kept out of FTS index entirely. |
| Embeddings | `EmbeddingWorker` embeds `message.content` (user-authored text) only. Link preview metadata excluded from embedding input. |
| Summarization | Link previews excluded from summarization prompt, or included as clearly demarcated untrusted block with LLM system prompt treating external content as data, not instructions. |
| Display | Phoenix default HTML escaping handles XSS. OG images via `<img>` with no `onerror`. URLs with `rel="noopener noreferrer ugc"`. |

### Key Principle

User-authored message content and externally-fetched preview metadata are never mixed in any pipeline input. Stored separately, embedded separately, summarized separately.

## Data Model

```
link_previews table:
  id              - bigserial primary key
  message_id      - bigint, references messages(id), indexed
  url             - string, the original URL from the message
  title           - string, max 200 chars (sanitized)
  description     - string, max 500 chars (sanitized)
  site_name       - string, max 100 chars
  image_url       - string, the OG image URL (not proxied)
  favicon_url     - string
  status          - string, "fetched" or "blocked"
  blocked_reason  - string, nullable ("safe_browsing", "blocklist", "fetch_error")
  inserted_at     - utc_datetime_usec
  updated_at      - utc_datetime_usec
```

One message can have multiple previews (multiple URLs). Status determines whether the UI renders a card or hides it.

## Components

| Component | Responsibility |
|-----------|---------------|
| `Slackex.Links.URLExtractor` | Regex extraction of URLs from message text, linkification for display |
| `Slackex.Links.SafetyChecker` | Google Safe Browsing API + compile-time domain blocklist |
| `Slackex.Links.MetadataParser` | HTTP fetch + OG tag parsing + sanitization (HTML strip, truncation, UTF8 validation) |
| `Slackex.Links.LinkPreview` | Ecto schema |
| `Slackex.Links.LinkPreviewWorker` | Oban worker orchestrating the pipeline |
| `SlackexWeb.ChatComponents.link_preview_card/1` | Phoenix component rendering the inline preview card |

## Error Handling

- **Fetch timeout (2s) or HTTP error**: Status `"blocked"`, reason `"fetch_error"`. Logged at `:warning`. No retry (Oban `max_attempts: 1`).
- **Blocked by Safe Browsing**: Status `"blocked"`, reason `"safe_browsing"`. Logged at `:warning`.
- **Blocked by domain list**: Status `"blocked"`, reason `"blocklist"`. No external call needed.
- **Missing OG tags**: Fall back to page `<title>`. If no title at all, status `"blocked"`, reason `"fetch_error"`.

No "pending" or "failed" states. A preview is either fetched or blocked.

## Display

Preview cards render inline below the message bubble. Rich card with:
- Colored left border (accent color)
- Site name + favicon
- Title (linked to URL)
- Description (truncated)
- OG image thumbnail (if present)

URLs in message text are linkified (converted to clickable `<a>` tags with `rel="noopener noreferrer ugc"`).

## Out of Scope

- Image proxying (direct OG image links for now)
- Preview caching/deduplication across messages
- User controls (dismiss preview, disable previews per-user)
- Preview for file uploads or media embeds
