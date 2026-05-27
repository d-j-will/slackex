# ADR-002: Sous→chat linkage via a Sous-owned `card_message_id`, not a `Message` FK

**Date:** 2026-05-27
**Status:** Accepted (supersedes the message-linkage approach in the Slice A spec §4/§5/§8)
**Context:** Sous Slice A — event-stream tracer bullet
**Related:** spec `./slice-a-event-stream-tracer-bullet.md`, ADR-001

---

## Context

The Slice A spec originally said `/decide` would insert the decision-card `Message` **inside the
work-item `Ecto.Multi`, atomically** with the event + projection + decision, and that the message
would carry a nullable `work_item_id` foreign key.

Inspecting the message pipeline showed this is incompatible with the architecture:

- `ChannelServer` (a per-channel GenServer) builds an **in-memory message map**, writes it to a
  cache, **broadcasts `"message.new"` synchronously**, and returns — see
  `lib/slackex/messaging/channel_server.ex:135-164`.
- Persistence to Postgres is **asynchronous and batched** via `BatchWriter`, using
  `Repo.insert_all/3` against an explicit field map (`to_row/1`), **bypassing changesets** —
  `lib/slackex/pipeline/batch_writer.ex:98-112`.

A direct `Repo.insert` of a message inside our own `Multi` would therefore:
1. Skip the ChannelServer cache → cache/DB divergence.
2. Skip the synchronous `"message.new"` broadcast → the card would not appear live (only on reload).
3. Race the batch writer on the same row.

The spec's atomicity claim cannot be honored without rewriting the message pipeline. There is no
synchronous-write escape hatch on `ChannelServer`.

## Decision

**Option Q — the Sous context owns the linkage.**

- `WorkItem` gains a `card_message_id` field, set via a `:card_posted` `WorkItemEvent` (so the
  linkage stays in the event log and the projection remains fully derivable).
- `/decide` flow: the `Ecto.Multi` creates the `:created` event + `WorkItem` + `Decision`
  (atomic — this is the event-stream core). **After** commit, the decision card is posted through
  the **existing** `Messaging.send_message/4` facade (the normal write-behind path, which caches,
  persists, and broadcasts correctly). The returned message id is recorded via a `:card_posted`
  event that sets `card_message_id`.
- The chat surface renders the card by loading `%{card_message_id => work_item}` for the active
  channel and branching in the message component. No change to `Message`, `ChannelServer`, or
  `BatchWriter`.

## Alternatives considered

### Option P — `work_item_id` FK on `messages`, threaded through the hot path
Add `work_item_id` to the `Message` schema + migration, thread it through
`ChannelServer.send_message` → the in-memory message map → `BatchWriter.to_row/1` → the
`Messaging` facade (5 touch points). The card renders correctly from the first `"message.new"`
broadcast (no two-step).

**Rejected because:** it modifies the performance-sensitive write-behind message path. Slackex's
incident history is concentrated there (v0.5.36 supervisor cascade, v0.5.58 streaming, write-behind
cache tuning). Slice A's purpose is to prove the event stream, not to take on risk in the message
pipeline. The clean render P buys is not worth touching the hot path for an occasional `/decide`.

## Consequences

### Positive
- The message pipeline is untouched; all change is contained in `Slackex.Sous` plus a small
  chat-render hook (load the card map + subscribe for the live upgrade).
- Respects the existing context boundary — Sous references messages, it does not rewrite how they
  are written.
- The seven event-sourcing-readiness invariants (spec §6) are **unaffected** — they govern the
  stream, not the card. `card_message_id` is itself set via a `:card_posted` event, so invariant #6
  (derivable projection) still holds.

### Negative / accepted trade-off
- **Two-step live render:** the `"message.new"` broadcast fires first (the message appears without
  the card chrome), then a Sous broadcast upgrades it to the styled card. This is ~1 RTT, visible
  only to the user who typed `/decide` (and any others viewing the channel live); on reload everyone
  sees the card correctly because the card map is loaded on mount. Treated as minor UX polish, not
  architectural debt.
- **Atomicity is scoped:** event + `WorkItem` + `Decision` commit atomically; the card post and the
  `:card_posted` event are a separate step. If the card post fails, the work item is "orphaned"
  (visible on the In Service board, no chat card) and the failure is logged. Acceptable for a tracer
  bullet; self-heals if retried.

## Horizon (not a Slice A decision — flagged so we choose it deliberately later)

The write-behind cache will add friction to any **future** feature that wants tight, synchronous
coupling between chat messages and the work-item stream. If Sous's thesis deepens toward *"every
message is an event in the stream"* (unifying the chat log and the work-item event log), that is a
deliberate architectural decision to make head-on — possibly unifying the two logs — rather than a
seam to keep patching. Slice A treats them as separate logs joined by a reference; revisit this when
(if) the message-as-event unification becomes a real requirement.
