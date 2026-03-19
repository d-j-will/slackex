# ADR-WHK-001: Webhook Message Pipeline Routing

## Status

Accepted

## Context

When a webhook delivers a message, it needs to be persisted to the database, broadcast via PubSub for real-time display, assigned a Snowflake ID for ordering, encrypted via Cloak, and indexed for search. The existing codebase has two paths that accomplish subsets of this:

1. **ChannelServer pipeline** (`Messaging.send_message/4`): The real-time path used by LiveView. Generates Snowflake ID, buffers in memory, broadcasts PubSub envelope immediately, persists asynchronously via BatchWriter. Includes permission checks, rate limiting, and push notification enqueueing.

2. **Direct database insert** (`Chat.Messages.send_message/3`): Synchronous Repo.insert through Message changeset. Generates Snowflake ID, runs Cloak encryption, populates search_content. Does NOT broadcast PubSub, does NOT populate in-memory cache, does NOT trigger push notifications or pipeline events.

Webhook messages must appear in real-time for connected LiveView clients, must have Snowflake IDs, must be encrypted, must be searchable, and must trigger downstream pipeline events (embeddings, link previews).

## Decision

Route webhook messages through `Messaging.send_message/4` (the ChannelServer pipeline).

## Alternatives Considered

### Alternative A: Direct database insert via `Chat.Messages.send_message/3`

Insert the message directly into PostgreSQL using the existing context function, then manually broadcast a PubSub envelope.

**Evaluation:**
- (+) Simpler: synchronous, no GenServer involvement
- (+) Immediate durability: message is in DB before HTTP response
- (-) Must manually replicate PubSub broadcast logic (envelope wrapping, topic construction)
- (-) Must manually replicate push notification enqueueing
- (-) ChannelServer in-memory cache becomes stale (connected clients see message via PubSub but ChannelServer queue is out of sync)
- (-) Pipeline events (`{:messages_persisted, ids}`) never fire, so embedding and link preview pipelines are not triggered
- (-) Any future additions to the ChannelServer pipeline (e.g., new post-persist hooks) must be duplicated

**Rejected because:** Creates a parallel message delivery path that diverges from the primary pipeline. Every pipeline enhancement must be duplicated. The ChannelServer cache staleness issue would cause inconsistencies for clients that re-fetch messages from the server.

### Alternative B: New dedicated webhook message function

Create a `Messaging.send_webhook_message/4` that combines direct insert + PubSub broadcast + pipeline events, bypassing ChannelServer.

**Evaluation:**
- (+) Can skip ChannelServer's per-user rate limiting (webhooks have their own)
- (+) Synchronous persistence (immediate durability)
- (-) Significant code duplication from ChannelServer (Snowflake generation, sender serialization, envelope wrapping, cache population, pipeline event broadcasting)
- (-) Same ChannelServer cache staleness problem as Alternative A
- (-) New function to maintain and keep in sync with evolving pipeline

**Rejected because:** Duplicates most of ChannelServer's message handling logic. The ChannelServer was designed to be the single authority for message lifecycle in an active channel. Creating a parallel path undermines that design.

## Consequences

### Positive

- **Single message pipeline**: All messages (human and bot) follow the same path. No divergence risk.
- **Full feature set**: Webhook messages automatically get Snowflake IDs, PubSub broadcast, in-memory caching, async persistence, push notifications, and pipeline events (embeddings, link previews).
- **Zero duplication**: No new message handling logic needed.
- **Future-proof**: Any pipeline enhancements automatically apply to webhook messages.

### Negative

- **Async persistence**: The webhook HTTP response (200) is returned before the message is durably persisted to PostgreSQL. The message is in the ChannelServer's in-memory buffer and will be flushed by BatchWriter within 2 seconds. This matches the existing durability model for all messages.
- **ChannelServer boot**: If no ChannelServer is running for the target channel, `Messaging.send_message/4` calls `ChannelSupervisor.ensure_started/1` which boots a new GenServer (loads recent messages from DB). This adds latency to the first webhook delivery for an inactive channel (~10-50ms). Subsequent deliveries are fast.
- **Per-user rate limiting**: ChannelServer applies its own per-user rate limit (10/second). This is separate from the per-webhook rate limit (60/minute) enforced at the controller level. The per-user limit is generous enough (10/second = 600/minute) that it will not conflict with the webhook rate limit (60/minute).
- **Permission check**: ChannelServer checks that the sender has a subscription with `send_message` permission. The webhook creation flow must ensure the bot user is subscribed to the target channel with at least "member" role. This is a feature, not a bug -- it prevents misconfigured webhooks from sending to channels the bot is not in.
