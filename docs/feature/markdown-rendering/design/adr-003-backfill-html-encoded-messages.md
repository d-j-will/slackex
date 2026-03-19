# ADR-003: Backfill Strategy for HTML-Encoded Message Content

## Status

Proposed

## Context

All existing messages in the database have content that was processed by `HtmlSanitizeEx.strip_tags/1` before storage. This means:
- `>` is stored as `&gt;` (breaks blockquotes)
- `<` is stored as `&lt;`
- `&` is stored as `&amp;`
- `"` is stored as `&quot;`
- `'` is stored as `&#39;`

After removing `strip_tags` from the storage pipeline (ADR-001), new messages will be stored with raw characters. Old messages still have encoded entities. The `unescape_html/1` function in `Markdown.to_html/1` handles this at render time, but this is a compatibility shim that should eventually be removed.

Additionally, `search_content` (the plaintext FTS companion column) also contains encoded entities, which degrades full-text search quality -- a query for `>` will not match `&gt;`.

The messages table uses Cloak encryption on the `content` field (stored as `encrypted_content` in PostgreSQL), so the migration cannot use a simple SQL UPDATE -- it must decrypt via Elixir, transform, and re-encrypt.

## Decision

Implement a three-phase deployment strategy:

**Phase 1 (immediate):** Remove `strip_tags`, keep `unescape_html` as compatibility shim. New messages stored clean; old messages rendered correctly via the shim.

**Phase 2 (backfill):** Add a Mix/Release task (similar to existing `backfill_embeddings`) that processes messages in batches:
1. Load batch of messages (e.g., 500 at a time)
2. For each message, Cloak decrypts `content` automatically via Ecto schema
3. Apply `unescape_html` transformation to the decrypted content
4. Update both `content` (re-encrypted by Cloak) and `search_content` (plaintext)
5. Track progress via last-processed message ID for resumability

**Phase 2 checkpoint (before bulk processing):** Select 10 random messages, run the full decrypt-transform-encrypt cycle on each, and compare the resulting encrypted bytes against the originals. This verifies Cloak round-trip integrity on real production data before committing to the full backfill. If any message fails the round-trip (e.g., key rotation issues, encoding edge cases), halt and investigate before proceeding.

**Ordering constraint:** `backfill_embeddings` must run AFTER the content backfill completes. Embeddings are generated from `search_content`, so running embeddings first would encode stale HTML-entity text into the vector space. After content backfill finishes, re-run `backfill_embeddings --force` to regenerate vectors from the cleaned `search_content`.

**Phase 3 (cleanup):** After backfill confirms all data is clean, remove `unescape_html` from `Markdown.to_html/1`.

**Temporary code comment requirement:** While `unescape_html/1` remains in `Markdown.to_html/1` during the Phase 1-2 transition, the call site must include a comment explaining why it exists and when it can be removed:

```elixir
# TEMPORARY: compensates for HTML-encoded entities in pre-migration messages.
# Remove after backfill migration (ADR-003 Phase 3) confirms all content is clean.
content |> unescape_html() |> chat_preprocess() |> ...
```

This prevents a future developer from removing it prematurely (before backfill completes) or keeping it permanently (after backfill is done) without understanding the context.

## Alternatives Considered

### Alternative 1: Keep unescape_html permanently

Never backfill; always unescape at render time. Rejected because:
- `search_content` still contains encoded entities, degrading FTS quality
- Embedding pipeline (all-MiniLM-L6-v2) processes `search_content` with encoded entities, reducing semantic quality
- Permanent compensating code for a one-time data issue
- Every future consumer of message content must know to unescape

### Alternative 2: Backfill via raw SQL on search_content only

Run SQL to replace `&gt;` with `>` etc. in `search_content` (plaintext column). Skip encrypted `content`. Rejected because:
- Leaves encrypted content with encoded entities permanently
- Any code path that reads `content` directly (not through `search_content`) still needs `unescape_html`
- Partial fix creates two truths about the same data

### Alternative 3: Ecto migration (blocking)

Run the backfill as part of a standard Ecto migration during deploy. Rejected because:
- Cloak decrypt/encrypt per row is CPU-intensive; large message tables could cause deployment timeouts
- Blocking migration would cause downtime
- Non-resumable if interrupted

## Consequences

### Positive

- Clean data throughout: encrypted content, search_content, and embeddings all contain raw user input
- `unescape_html` can be fully removed after Phase 3 -- no permanent compatibility shim
- Idempotent: running `unescape_html` on already-clean content is a no-op (no `&gt;` sequences to process)
- Resumable: tracking last-processed ID allows restart without re-processing
- Non-blocking: release task runs in background, does not affect deploy

### Negative

- Phase 2 requires careful testing of Cloak round-trip integrity (decrypt, transform, re-encrypt)
- During Phase 1-2 transition, `unescape_html` must remain in the render path
- Backfill task runtime depends on message count; production has enough messages to take non-trivial time
- Must coordinate with embedding backfill -- after content migration, embeddings based on old `search_content` become stale (can re-run `backfill_embeddings` after)
