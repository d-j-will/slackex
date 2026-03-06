# RCA: Pipeline Events Bridge Never Connected (v0.5.47 - v0.5.64)

**Date:** 2026-03-06
**Severity:** P2 -- two features silently broken in production, no data loss
**Duration:** ~18 hours from link preview deploy (v0.5.47) to fix (v0.5.64); embeddings affected since v0.5.36
**Trigger:** User reported link previews not appearing in production despite feature being enabled
**Versions affected:** Embeddings from v0.5.36; link previews from v0.5.47 (fixed in v0.5.64)

## Impact

- **Link previews**: Zero Oban jobs enqueued, zero previews generated for any message sent in production
- **Embedding indexing**: New messages never indexed for semantic search after batch persistence (backfill/reconciliation still worked)
- Both features appeared fully functional in tests and passed all CI quality gates
- No application instability, no data loss -- features were silently inert

## Architecture Context

The Phase 4 spec (`specs/04-phase-4-intelligence.md`) designed an **event bridge** pattern:

```
ChannelServer → BatchWriter.async_insert_batch → DB insert
    ↓ (on success)
PubSub.broadcast("pipeline:events", {:messages_persisted, message_ids})
    ↓
LinkPreviewListener ──→ enqueue LinkPreviewWorker (Oban)
PersistenceListener ──→ enqueue EmbeddingWorker (Oban)
```

The spec explicitly stated: *"After successful batch persistence, `BatchWriter` broadcasts `{:messages_persisted, message_ids}` on the internal PubSub topic `"pipeline:events"`."*

The listeners were implemented and subscribed correctly. The workers were implemented and tested. The broadcast was never added.

## Timeline

| Version | Date | Change | Event bridge status |
|---------|------|--------|-------------------|
| v0.5.36 | 2026-03-04 | Embeddings: PersistenceListener, ReconciliationWorker | Listener deployed, subscribed to `pipeline:events` -- but nobody broadcasts |
| v0.5.47 | 2026-03-06 03:00 | Link previews: full stack (schema, worker, listener, LiveView) | LinkPreviewListener deployed, also subscribed -- same dead topic |
| v0.5.47-v0.5.63 | 2026-03-06 | 8 deploys of other features (markdown, summarization) | Event bridge still missing; nobody notices |
| v0.5.64 | 2026-03-06 20:43 | Fix: broadcast from ChannelServer `handle_info({:batch_result, ...})` | Both listeners now receive events |

## Root Cause Analysis (5 Whys)

**WHY 1: Why weren't link previews appearing in production?**
`LinkPreviewListener` never received `{:messages_persisted, message_ids}` events, so it never enqueued `LinkPreviewWorker` Oban jobs. Zero jobs = zero previews.

**WHY 2: Why did the listener never receive events?**
Nobody was broadcasting to the `"pipeline:events"` PubSub topic. The spec assigned this responsibility to `BatchWriter`, but the broadcast was never implemented in any module.

**WHY 3: Why wasn't the missing broadcast caught during implementation?**
The feature was built bottom-up across multiple sessions: schema → worker → listener → LiveView. Each layer was tested in isolation. Listener tests sent `{:messages_persisted, ids}` directly via `PubSub.broadcast`, which verified the listener's behavior but masked the fact that no production code path produced those events.

**WHY 4: Why didn't integration tests catch the gap?**
There was no end-to-end test that exercised the full pipeline: send message → ChannelServer → BatchWriter → PubSub → listener → Oban job. Each component's tests faked its upstream dependency. The spec called for an event bridge, but no test verified the bridge existed.

**WHY 5: Why was the spec's design not followed during implementation?**
The spec placed the broadcast in `BatchWriter`, but `BatchWriter` runs inside `Task.Supervisor` async tasks. Adding PubSub broadcasts from async tasks caused Ecto SQL Sandbox poisoning in tests (listeners grabbed the shared sandbox connection, then test teardown killed the connection mid-query). The implementation was blocked by this interaction, and the broadcast was inadvertently omitted rather than relocated.

## Root Causes

| # | Root Cause | Category |
|---|-----------|----------|
| RC1 | Event bridge broadcast never implemented -- spec designed it, implementation missed it | Implementation gap |
| RC2 | Listener unit tests faked the upstream event, masking the missing producer | Test design |
| RC3 | No integration test for the full message → persistence → event → job pipeline | Test gap |
| RC4 | Silent failure mode -- listeners subscribed to a topic with zero publishers, with no alerting | Observability |

## Fix

**Broadcast location:** ChannelServer `handle_info({:batch_result, ref, :ok})` in `lib/slackex/messaging/channel_server.ex`, not BatchWriter.

This is architecturally better than the spec's original design because:
1. ChannelServer is a GenServer with a predictable mailbox -- broadcasts are processed sequentially and are drainable via `:sys.get_state/2`
2. BatchWriter runs inside `Task.Supervisor` async tasks -- PubSub broadcasts from tasks interact poorly with Ecto SQL Sandbox shared mode (listeners pick up the task's sandbox connection, which gets torn down at test exit)
3. ChannelServer already handles the `{:batch_result, ref, :ok}` callback and has the message list in its `in_flight` map

**Test stability:** Added listener drain in `test/support/data_case.ex` `on_exit` -- calls `:sys.get_state/2` on `LinkPreviewListener` and `PersistenceListener` before stopping the sandbox, ensuring they finish any in-progress FunWithFlags DB queries.

## Failed Approaches

During the fix session, several approaches were attempted before arriving at the ChannelServer solution:

1. **Broadcast from BatchWriter inside transaction** -- Sandbox poisoning: listeners ran queries on the transaction's connection
2. **Broadcast from BatchWriter after transaction** -- Still poisoned: `Task.Supervisor` async tasks share the test's sandbox connection
3. **Spawn a new process for the broadcast** -- Same problem: any process using PubSub.broadcast synchronously delivers to listeners in-line
4. **Stop/restart listeners around tests** -- Fragile, didn't address the fundamental issue

The breakthrough came from researching Ecto SQL Sandbox documentation: shared mode allows *any process on the node* to use the connection. The fix had to ensure broadcasts came from a process with predictable lifecycle (GenServer), not an ephemeral task.

## Corrective Actions

| # | Action | Status |
|---|--------|--------|
| CA1 | Wire up `pipeline:events` broadcast from ChannelServer | Done (v0.5.64) |
| CA2 | Add listener drain to DataCase for test stability | Done (v0.5.64) |
| CA3 | Write RCA document | Done |
| CA4 | Add integration test: message send → listener receives event → job enqueued | TODO |
| CA5 | Add startup log or health check confirming pipeline:events has active subscribers | TODO |

## Lessons Learned

1. **Spec-to-implementation traceability is critical.** The spec explicitly described the event bridge, but there was no checklist or acceptance test verifying it existed. When features are built across multiple sessions, integration points between components are the most likely to be dropped.

2. **Unit tests that fake upstream events prove the handler works, not the system.** `LinkPreviewListener` tests broadcasting `{:messages_persisted, ids}` directly proved the listener responds correctly -- but that's testing the consumer, not the producer-consumer contract. An integration test that starts from `Messaging.send_message` would have caught this immediately.

3. **Silent subscription to an empty topic is a dangerous failure mode.** A PubSub subscriber that never receives events looks identical to a subscriber with no work to do. Consider logging at startup when a listener subscribes, and periodic health checks that verify recent event flow.

4. **Ecto SQL Sandbox shared mode is a system-wide concern.** Any process on the node can use the shared connection. PubSub.broadcast is synchronous -- it delivers messages to subscribers in the *calling process*, meaning listeners execute their DB queries on whatever connection the broadcaster holds. This makes the broadcast location an architectural decision, not just a code organization choice.
