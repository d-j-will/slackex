# Agent-Observable Ops Hardening Implementation Plan

> **For agentic workers:** REQUIRED: execute this plan in small, verifiable steps. Every new MCP surface and every new cross-context bridge must have integration coverage.

**Goal:** Make Slackex operationally legible to AI agents by exposing runtime health, queue state, and dark-factory state through MCP, then prove one dogfood workflow where an agent can inspect the system and report status back into Slackex.

**Architecture:** Reuse the existing MCP server, telemetry stack, factory state machine, and channel notifier. Add a small read-side ops layer, extend MCP resources and serializers, harden telemetry polling visibility, and verify the full agent-facing path with integration tests.

**Tech Stack:** Phoenix Plug MCP server, `Slackex.Factory`, `Slackex.Messaging`, `SlackexWeb.Telemetry`, Oban, Phoenix.PubSub.

**Parent docs:**
- `docs/research/vision-roadmap-2026-03-08.md`
- `docs/feature/mcp-server/design/architecture.md`
- `docs/runbooks/observability.md`
- `docs/architecture/realtime-chat.md`

**Related planning docs:**
- `docs/plans/2026-04-02-agent-observable-ops-hardening-plan-v2.md` - narrowed MVP execution plan chosen after review
- `docs/plans/2026-04-02-agent-observable-ops-hardening-auth-matrix.md` - v2 auth boundary and payload contract
- `docs/plans/2026-04-02-agent-observable-ops-hardening-decision-memo.md` - why v2 replaced v1 as the execution plan

---

## Existing State

- MCP is already live at `/mcp` with authenticated tools and resources in `lib/slackex_web/mcp/server.ex`.
- MCP already supports messaging and dark-factory tools, but read-only operational visibility is minimal.
- Observability foundations already exist: OTEL setup in `lib/slackex/application.ex`, Prometheus metrics in `lib/slackex_web/telemetry.ex`, and `/metrics` export in `lib/slackex_web/plugs/metrics_exporter.ex`.
- Factory lifecycle state already exists in `lib/slackex/factory.ex`, with PubSub updates and channel-thread notifications via `lib/slackex/factory/channel_notifier.ex`.
- Current telemetry pollers still contain silent rescue paths in `lib/slackex_web/telemetry.ex`, which conflicts with the project's documented observability discipline.

---

## Non-Goals

- Do not add full SSE subscription support to MCP in this phase.
- Do not build new dark-factory orchestration stages or multi-agent consensus loops here.
- Do not replace Grafana or Prometheus with an MCP-only observability surface.
- Do not start Tauri, huddles, or pair-programming implementation in this phase.

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `lib/slackex/ops/system_summary.ex` | Read-only runtime snapshot: node, cluster, queue, presence, messaging, and feature-flag status |
| `test/slackex/ops/system_summary_test.exs` | Unit tests for the ops summary contract |
| `test/slackex_web/mcp/ops_resources_test.exs` | Integration tests for new MCP operational resources |
| `docs/runbooks/agent-ops-dogfood.md` | Manual dogfood workflow for agents inspecting and reporting system state |

### Modified Files

| File | Change |
|---|---|
| `lib/slackex/factory.ex` | Add read-side helpers for run inspection suitable for MCP resources |
| `lib/slackex_web/mcp/server.ex` | Add operational and factory-inspection resources |
| `lib/slackex_web/mcp/serializer.ex` | Serialize ops snapshots, queue state, factory runs, and factory events |
| `lib/slackex_web/telemetry.ex` | Replace silent rescue paths with warning logs and clearer helper structure |
| `test/slackex_web/mcp/server_test.exs` | Extend existing MCP tests to cover new resource listings if preferred over a separate file |
| `test/slackex_web/mcp/factory_tools_test.exs` | Add dogfood-style read-after-write checks against new resources |

---

## Task 1: Add a Read-Only Ops Summary Layer

**Files:**
- Create: `lib/slackex/ops/system_summary.ex`
- Create: `test/slackex/ops/system_summary_test.exs`

- [ ] **Step 1: Write failing tests for a stable summary contract**

Create tests for `Slackex.Ops.SystemSummary.snapshot/0` that assert the returned map includes:

- app identity and current node
- cluster node count
- `dark_factory` and other relevant feature-flag status
- connected user count
- active `ChannelServer` count
- Oban queue running counts for `:default`, `:notifications`, `:embeddings`, and `:link_previews`

The tests should not assert exact production values, only shape and key presence.

- [ ] **Step 2: Implement `Slackex.Ops.SystemSummary`**

The module should gather a lightweight runtime snapshot from existing sources:

- `node/0` and `Node.list/0`
- `Slackex.Messaging.channel_count/0`
- `SlackexWeb.Presence.list("users:lobby") |> map_size()`
- `Oban.check_queue/1` using the already-documented `%{running: running}` return shape
- `FunWithFlags.enabled?/1` for key feature flags relevant to the vision loop

Keep this module read-only and side-effect free.

- [ ] **Step 3: Keep queue inspection defensive but visible**

If Oban queue inspection fails, return a shaped error value in the snapshot and log a warning rather than swallowing the failure silently.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/slackex/ops/system_summary_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/ops/system_summary.ex test/slackex/ops/system_summary_test.exs
git commit -m "feat(ops): add read-only system summary snapshot"
```

---

## Task 2: Add Factory Read-Side Inspection Helpers

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify or create tests in: `test/slackex/factory_test.exs`

- [ ] **Step 1: Add failing tests for read-side inspection**

Add tests for helpers such as:

- `list_recent_runs/2` or equivalent scoped read helper
- `get_run/1`
- `list_events/1` shape expectations suitable for MCP serialization

For v1, keep run listing scoped to the bot user tied to the MCP token unless you intentionally widen authorization in the design.

- [ ] **Step 2: Implement minimal helpers in `Slackex.Factory`**

Add read helpers that make MCP resource wiring simple and explicit. Preferred shapes:

- recent runs list with optional status filter and limit
- single run lookup
- existing event list reuse

Do not add new state transitions in this phase.

- [ ] **Step 3: Verify existing tests still pass**

Run:

```bash
mix test test/slackex/factory_test.exs test/slackex/factory/lifecycle_worker_test.exs
```

- [ ] **Step 4: Commit**

```bash
git add lib/slackex/factory.ex test/slackex/factory_test.exs
git commit -m "feat(factory): add read-side inspection helpers for MCP"
```

---

## Task 3: Extend MCP With Operational Resources

**Files:**
- Modify: `lib/slackex_web/mcp/server.ex`
- Modify: `lib/slackex_web/mcp/serializer.ex`
- Create: `test/slackex_web/mcp/ops_resources_test.exs`

- [ ] **Step 1: Define the new resource surface**

Add read-only resources such as:

- `tenun:///ops/summary`
- `tenun:///ops/queues`
- `tenun:///ops/factory/runs`
- `tenun:///ops/factory/runs/:id`
- `tenun:///ops/factory/runs/:id/events`

Keep the surface small. Each resource should answer one clear question.

- [ ] **Step 2: Extend the MCP serializer boundary**

Add serializer functions for:

- ops summary snapshot
- queue summaries
- factory run summary
- factory run detail
- factory event

Do not expose raw structs directly.

- [ ] **Step 3: Implement `resources/0` and `read_resource/2` additions**

Wire the new resources in `lib/slackex_web/mcp/server.ex`.

Important constraints:

- keep reads authenticated
- keep factory run visibility scoped to the bot user unless explicitly widened
- return clean JSON payloads, not Elixir inspection output

- [ ] **Step 4: Add MCP integration tests**

Cover at least:

- resources/list includes the new ops resources
- reading `tenun:///ops/summary` returns the expected JSON shape
- reading factory runs returns queued and transitioned runs for the authenticated bot
- reading run events returns lifecycle events after queue, claim, and heartbeat

- [ ] **Step 5: Run focused MCP tests**

Run:

```bash
mix test test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/factory_tools_test.exs test/slackex_web/mcp/ops_resources_test.exs
```

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/mcp/server.ex lib/slackex_web/mcp/serializer.ex test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/factory_tools_test.exs test/slackex_web/mcp/ops_resources_test.exs
git commit -m "feat(mcp): expose ops and factory inspection resources"
```

---

## Task 4: Harden Telemetry Polling Visibility

**Files:**
- Modify: `lib/slackex_web/telemetry.ex`
- Create or modify tests around telemetry measurements

- [ ] **Step 1: Remove silent rescue paths**

Replace the current `rescue _ -> :ok` patterns in periodic measurements with warning logs and safe fallback behavior.

This applies especially to:

- `measure_oban_queue_depth/0`
- `measure_connected_users/0`

- [ ] **Step 2: Extract helpers to keep control flow shallow**

Refactor queue and presence measurement into small helper functions so the error handling is explicit and Credo-friendly.

- [ ] **Step 3: Add tests for visible failure behavior**

Add tests that prove broken measurement paths do not crash the poller and do emit warnings.

- [ ] **Step 4: Run telemetry-focused tests**

Run the relevant test file plus metrics exporter tests:

```bash
mix test test/slackex_web/plugs/metrics_exporter_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/telemetry.ex test/slackex_web/plugs/metrics_exporter_test.exs
git commit -m "fix(telemetry): make periodic measurement failures visible"
```

---

## Task 5: Prove the Dogfood Workflow

**Files:**
- Modify: `test/slackex_web/mcp/factory_tools_test.exs`
- Create: `docs/runbooks/agent-ops-dogfood.md`

- [ ] **Step 1: Add one end-to-end dogfood test**

Add an integration test that proves this flow:

1. queue a factory run through MCP
2. claim it and heartbeat progress through MCP
3. read factory run state through the new MCP resources
4. read system summary through MCP
5. use existing `send_message` or channel notifier behavior to surface status back into Slackex

The point is to prove the system is inspectable by an agent, not just writable.

- [ ] **Step 2: Write a short manual runbook**

Create `docs/runbooks/agent-ops-dogfood.md` with:

- how to query `tools/list` and `resources/list`
- which ops resources to inspect first
- a short example workflow for following a factory run
- expected success signals

- [ ] **Step 3: Run the full targeted test slice**

Run:

```bash
mix test test/slackex/factory_test.exs test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/factory_tools_test.exs test/slackex_web/mcp/ops_resources_test.exs test/slackex/ops/system_summary_test.exs
```

- [ ] **Step 4: Commit**

```bash
git add test/slackex_web/mcp/factory_tools_test.exs docs/runbooks/agent-ops-dogfood.md
git commit -m "test(ops): prove MCP dogfood workflow for system and factory inspection"
```

---

## Acceptance Criteria

- An authenticated MCP client can list and read operational resources without scraping the UI.
- `tenun:///ops/summary` returns a stable JSON snapshot including node, cluster, queue, presence, messaging, and feature-flag status.
- An authenticated MCP client can inspect factory runs and factory run events tied to its bot identity.
- Telemetry measurement failures are visible in logs rather than being silently swallowed.
- At least one integration test proves the full dogfood workflow from factory mutation to MCP inspection.
- Existing MCP messaging and factory tools continue to pass their current tests.

---

## Suggested Execution Order

1. Task 1 - ops summary layer
2. Task 2 - factory read-side helpers
3. Task 3 - MCP resources and serializer updates
4. Task 4 - telemetry hardening
5. Task 5 - dogfood test and runbook

This order keeps the phase additive: first build clean read models, then expose them, then harden visibility, then prove the workflow end to end.

---

## What Comes After This Phase

If this phase succeeds, the next logical phase is a small dark-factory dogfood slice that uses the new operational visibility to track and verify one real implementation run. After that, Tauri becomes more compelling because it can surface the same status loop through native notifications and an always-on shell.
