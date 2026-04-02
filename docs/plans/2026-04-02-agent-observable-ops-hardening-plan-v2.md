# Agent-Observable Ops Hardening Implementation Plan v2

> **For agentic workers:** REQUIRED: implement this plan in narrow, verifiable slices. Do not widen MCP visibility or add new write capabilities without explicit tests for authorization and failure behavior.

**Goal:** Deliver a minimal, trustworthy agent-facing ops snapshot for Slackex, expose it through MCP, and prove one dogfood loop where an authenticated MCP client can inspect the system snapshot and report status back into Slackex.

**Why v2 exists:** The original plan aimed in the right direction, but it was too broad for a safe first slice. This revision narrows scope, defines the security boundary first, uses more accurate metric semantics, and defers broader factory/queue resource expansion until the first snapshot is proven useful.

**Architecture:** Keep the first slice read-only and small. Reuse the existing MCP server, serializer boundary, telemetry pollers, and message send path. Add a tiny ops snapshot layer with honest field names and partial-failure reporting. Do not add SSE, new factory read resources, or new orchestration behavior in this phase.

**Tech Stack:** Phoenix Plug MCP server, `Slackex.Messaging`, `SlackexWeb.Telemetry`, Oban, Phoenix.Presence, FunWithFlags.

**Parent docs:**
- `docs/research/vision-roadmap-2026-03-08.md`
- `docs/feature/mcp-server/design/architecture.md`
- `docs/runbooks/observability.md`
- `docs/plans/2026-04-02-agent-observable-ops-hardening-plan.md`

**Companion docs:**
- `docs/plans/2026-04-02-agent-observable-ops-hardening-auth-matrix.md` - auth boundary, payload contract, and negative-test requirements
- `docs/plans/2026-04-02-agent-observable-ops-hardening-decision-memo.md` - rationale for choosing v2 over v1

---

## MVP Outcome

At the end of this phase:

- an authenticated MCP client can read exactly one new resource: `tenun:///ops/summary`
- that resource returns a small, explicit JSON snapshot with accurate field names and a timestamp
- snapshot probes that fail are visible in logs and represented in `partial_failures`
- one integration test proves an MCP client can read the snapshot and post a summary message back into Slackex using the existing `send_message` tool

This is an **ops snapshot MVP**, not full agent-queryable observability.

---

## Non-Goals

- Do not add `tenun:///ops/queues` in this phase.
- Do not add `tenun:///ops/factory/runs` or run-event resources in this phase.
- Do not add full SSE or MCP subscription support.
- Do not change factory claim/verification authorization in this phase.
- Do not expose cluster-wide or feature-flag state unless explicitly approved in the auth matrix task.

---

## Task 0: Define Resource Contract And Authorization Matrix

**Files:**
- Create: `docs/plans/2026-04-02-agent-observable-ops-hardening-auth-matrix.md`

- [x] **Step 1: Define the resource audience**

Decide whether `tenun:///ops/summary` is visible to:

- all authenticated MCP tokens, or
- a narrower class of tokens once capability/scoping exists

For this MVP, the simplest acceptable choice is **all authenticated MCP tokens**, but only if the payload is kept low-sensitivity.

- [x] **Step 2: Define the exact payload contract**

Specify the exact JSON fields for `tenun:///ops/summary`:

```json
{
  "generated_at": "2026-04-02T12:34:56Z",
  "node": "slackex@app1",
  "active_channel_servers": 12,
  "lobby_presence_count": 5,
  "queue_running_counts": {
    "default": 0,
    "notifications": 1,
    "embeddings": 0,
    "link_previews": 0
  },
  "partial_failures": {
    "active_channel_servers": null,
    "presence": null,
    "queues": null
  }
}
```

Rules:

- use accurate names, not overloaded observability claims
- include `generated_at`
- include `partial_failures`
- use a fixed `partial_failures` vocabulary, not free-form error strings
- do not include secrets, token data, raw config, or user-identifiable payloads
- fix the queue keys as `default`, `notifications`, `embeddings`, and `link_previews` for the MVP contract

- [x] **Step 3: Define negative tests before code**

Document required negative tests:

- unauthenticated request denied
- invalid token denied
- revoked token denied
- snapshot probe failure still returns shaped JSON when appropriate
- no Elixir inspection strings in MCP responses
- `resources/list` exposes exactly one new MVP resource: `tenun:///ops/summary`

- [x] **Step 4: Commit the auth matrix / contract doc**

```bash
git add docs/plans/2026-04-02-agent-observable-ops-hardening-auth-matrix.md
git commit -m "docs(ops): define auth matrix and summary contract for MCP ops snapshot"
```

---

## Task 1: Harden Telemetry Polling Visibility First

**Files:**
- Modify: `lib/slackex_web/telemetry.ex`
- Modify or create telemetry-focused tests

- [x] **Step 1: Remove silent rescue paths**

Replace the current `rescue _ -> :ok` behavior in:

- `measure_oban_queue_depth/0`
- `measure_connected_users/0`

with visible sanitized warning logs plus safe fallback behavior.

- [x] **Step 2: Keep the code shallow and testable**

Extract queue and presence probes into helpers that return either `{:ok, value}` or `{:error, reason}`.

- [x] **Step 3: Add tests for visible failure behavior**

Verify:

- failures do not crash the poller
- warnings are emitted
- fallback behavior remains deterministic

- [x] **Step 4: Run targeted tests**

```bash
mix test test/slackex_web/plugs/metrics_exporter_test.exs
```

- [x] **Step 5: Commit**

```bash
git add lib/slackex_web/telemetry.ex test/slackex_web/plugs/metrics_exporter_test.exs
git commit -m "fix(telemetry): make measurement probe failures visible"
```

---

## Task 2: Add A Minimal Ops Snapshot Layer

**Files:**
- Create: `lib/slackex/ops/system_summary.ex`
- Create: `test/slackex/ops/system_summary_test.exs`

- [x] **Step 1: Write failing tests for the exact summary contract**

Test `Slackex.Ops.SystemSummary.snapshot/0` for:

- presence of all fields from the contract doc
- ISO8601 `generated_at`
- integer counts for successful probes
- exact fallback shapes for failed probes
- `null` or fixed sanitized codes inside `partial_failures`

Do not assert exact runtime counts.

- [x] **Step 2: Implement the snapshot with honest field names**

Use existing sources only:

- `node/0`
- `Slackex.Messaging.channel_count/0`
- `SlackexWeb.Presence.list("users:lobby") |> map_size()`
- `Oban.check_queue/1` for running counts on existing queues

Important:

- name the presence field `lobby_presence_count`, not `connected_users`
- name queue data `queue_running_counts`, not `queue_depth`
- add `partial_failures` entries when probes fail

- [x] **Step 3: Keep partial failures explicit**

If a probe fails:

- log a sanitized warning
- return a fallback value for the affected field
- record the fixed failure code from the auth matrix in `partial_failures`

At minimum, handle partial-failure behavior for:

- `active_channel_servers`
- `presence`
- `queues`

- [x] **Step 4: Run focused tests**

```bash
mix test test/slackex/ops/system_summary_test.exs
```

- [x] **Step 5: Commit**

```bash
git add lib/slackex/ops/system_summary.ex test/slackex/ops/system_summary_test.exs
git commit -m "feat(ops): add minimal MCP-facing ops snapshot"
```

---

## Task 3: Expose The Snapshot Through MCP

**Files:**
- Modify: `lib/slackex_web/mcp/server.ex`
- Modify: `lib/slackex_web/mcp/serializer.ex`
- Create: `test/slackex_web/mcp/ops_resources_test.exs`

- [x] **Step 1: Add one new MCP resource only**

Add:

- `tenun:///ops/summary`

Do not add any other ops resources in this task.

- [x] **Step 2: Add serializer support**

Create a serializer function dedicated to the ops snapshot contract. The serializer must:

- preserve the exact contract fields
- avoid leaking structs or internal terms
- return clean JSON-friendly maps

- [x] **Step 3: Implement `read_resource/2` support**

Wire `tenun:///ops/summary` in `lib/slackex_web/mcp/server.ex`.

Constraints:

- authenticated MCP only
- no Elixir inspection output
- no transport-specific logic inside the ops module

- [x] **Step 4: Add integration tests**

Cover:

- `resources/list` includes exactly one new MVP resource: `tenun:///ops/summary`
- reading `tenun:///ops/summary` returns the documented JSON shape
- unauthenticated access remains denied
- invalid token remains denied
- revoked token remains denied
- the payload contains no Elixir inspection strings or raw internal error text

- [x] **Step 5: Run MCP tests**

```bash
mix test test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/ops_resources_test.exs
```

- [x] **Step 6: Commit**

```bash
git add lib/slackex_web/mcp/server.ex lib/slackex_web/mcp/serializer.ex test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/ops_resources_test.exs
git commit -m "feat(mcp): expose minimal ops summary resource"
```

---

## Task 4: Prove One Deterministic Dogfood Workflow

**Files:**
- Modify: `test/slackex_web/mcp/factory_tools_test.exs` or create a new dedicated dogfood test file
- Create: `docs/runbooks/agent-ops-dogfood.md`

- [x] **Step 1: Add one narrow end-to-end test**

Prove this exact flow:

1. MCP client reads `tenun:///ops/summary`
2. MCP client calls existing `send_message`
3. the posted message includes a short summary derived from the snapshot

This proves the agent-visible read path and the existing write path can be combined in one loop.

- [x] **Step 2: Keep the proof deterministic**

Do not rely on:

- channel notifier side effects
- async factory lifecycle transitions
- presence timing changes

The test should prove inspectability, not distributed orchestration.

- [x] **Step 3: Write the manual runbook**

Create `docs/runbooks/agent-ops-dogfood.md` with:

- how to authenticate an MCP client
- how to call `resources/list`
- how to read `tenun:///ops/summary`
- how to send a human-readable status message back into a channel
- what a successful run looks like

- [x] **Step 4: Run the full targeted slice**

```bash
mix test test/slackex/ops/system_summary_test.exs test/slackex_web/mcp/server_test.exs test/slackex_web/mcp/ops_resources_test.exs test/slackex_web/mcp/factory_tools_test.exs
```

- [x] **Step 5: Commit**

```bash
git add test/slackex_web/mcp/factory_tools_test.exs docs/runbooks/agent-ops-dogfood.md
git commit -m "test(ops): prove MCP ops snapshot read and status reporting loop"
```

---

## Acceptance Criteria

- The plan’s auth matrix exists as a separate doc before implementation begins.
- Telemetry probe failures are visible in logs rather than silently swallowed.
- An authenticated MCP client can list and read exactly one new resource: `tenun:///ops/summary`.
- The snapshot contract includes `generated_at`, `node`, `active_channel_servers`, `lobby_presence_count`, `queue_running_counts`, and `partial_failures` with exact field names and fixed queue keys.
- The snapshot uses accurate names and does not claim more observability fidelity than it actually provides.
- Partial failures use fixed sanitized codes and exact tested fallback shapes.
- At least one integration test proves an MCP client can read the snapshot and post a derived status message through existing Slackex messaging.

---

## Deferred Follow-Up Work

If this MVP proves useful, the next phase can consider:

- expanding the auth model beyond “all authenticated MCP tokens”
- adding additional ops resources such as queue detail
- adding factory run and run-event read resources
- revisiting whether broader ops data belongs in MCP at all or should remain human-dashboard-only

Those should happen only after this first snapshot proves useful, cheap, and safe.
