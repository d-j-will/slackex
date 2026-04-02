# Agent-Observable Ops Snapshot Auth Matrix And Contract

This document defines the security boundary and payload contract for the v2 ops snapshot MVP described in `docs/plans/2026-04-02-agent-observable-ops-hardening-plan-v2.md`.

Related docs:

- `docs/plans/2026-04-02-agent-observable-ops-hardening-plan-v2.md` - execution plan that consumes this contract
- `docs/plans/2026-04-02-agent-observable-ops-hardening-decision-memo.md` - why the narrower v2 plan was chosen
- `docs/plans/2026-04-02-agent-observable-ops-hardening-plan.md` - original broader concept retained for reference

---

## 1. Scope Of This Document

This auth matrix applies only to the MVP ops snapshot resource:

- `tenun:///ops/summary`

It does **not** define authorization for future resources such as:

- queue detail resources
- factory run read resources
- event-stream or SSE resources
- capability-scoped admin or operator tokens

Those require a separate authorization review when they are proposed.

---

## 2. MVP Security Decision

**Decision:** `tenun:///ops/summary` is readable by **all authenticated MCP tokens** for the MVP.

### Why this is acceptable in v1

- the resource is intentionally low sensitivity
- the payload contains no secrets, tokens, user identities, message content, or configuration values
- the snapshot is aggregate and operational, not per-user or per-channel
- the current MCP authentication model distinguishes valid bot identities but does not yet support scopes/capabilities

### What makes this decision safe enough

The payload must stay limited to low-sensitivity fields only. If the payload expands beyond that boundary, this decision must be revisited before implementation.

---

## 3. Resource Audience Matrix

| Resource | Audience | Sensitivity | Allowed In MVP | Notes |
|---|---|---|---|---|
| `tenun:///ops/summary` | Any authenticated MCP token | Low | Yes | Low-sensitivity aggregate snapshot only |
| `tenun:///ops/queues` | Undefined | Medium | No | Deferred; queue detail may expose more operational posture than intended |
| `tenun:///ops/factory/runs` | Undefined | Medium | No | Deferred pending factory read auth decision |
| `tenun:///ops/factory/runs/{id}` | Undefined | Medium | No | Deferred pending factory read auth decision |
| `tenun:///ops/factory/runs/{id}/events` | Undefined | Medium | No | Deferred pending factory read auth decision |

---

## 4. Exact Payload Contract

The `tenun:///ops/summary` resource must return JSON with exactly this shape:

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

### Field semantics

| Field | Meaning | Allowed source |
|---|---|---|
| `generated_at` | UTC timestamp when the snapshot was built | `DateTime.utc_now/0` |
| `node` | Current Erlang node name; opaque and environment-dependent, not a stable cluster identity | `node/0` |
| `active_channel_servers` | Count of active `ChannelServer` processes | `Slackex.Messaging.channel_count/0` |
| `lobby_presence_count` | Number of presences currently visible in `users:lobby`; not a true system-wide connected-user count | `SlackexWeb.Presence.list("users:lobby") |> map_size()` |
| `queue_running_counts` | Count of currently running jobs per queue | `Oban.check_queue/1` |
| `partial_failures` | Per-probe sanitized failure codes or `null` | Snapshot assembly logic |

### Naming rules

- Use exact field names from this document.
- Do not rename fields to broader claims like `connected_users` or `queue_depth`.
- Do not add extra fields in the MVP without updating this document first.
- The queue keys `default`, `notifications`, `embeddings`, and `link_previews` are fixed MVP contract keys. Changing them is a contract change and requires a doc update.

---

## 5. Explicitly Forbidden Data

The MVP snapshot must **not** include:

- any token value, token hash, or auth metadata
- environment variables or config values
- feature-flag states
- cluster membership lists or hostnames beyond the current node name
- user IDs, usernames, display names, or message content
- channel IDs, DM IDs, or thread IDs
- raw exception structs or stack traces

Payloads must also not include raw inspected terms, adapter/library error text, module names, or database/driver error strings.

If future work needs any of these, it requires a new authorization review.

---

## 6. Partial Failure Contract

Snapshot assembly must be resilient but visible.

### Failure-code vocabulary

`partial_failures` values are a closed set of sanitized codes for the MVP:

- `null`
- `channel_server_probe_failed`
- `presence_probe_failed`
- `queue_probe_failed`

Raw exception messages must never appear in the MCP payload.

### Rules

- If a probe succeeds, return the normal value and `null` for its error slot.
- If a probe fails, return a safe fallback value and the corresponding sanitized failure code.
- Failures must be logged as sanitized warnings.
- The resource should still return `200` for partial probe failures as long as the overall snapshot can be built.
- If `partial_failures.<key> != null`, the paired field is a fallback value and must not be treated as observed truth.

### Required fallback behavior

| Probe | Fallback value | `partial_failures` key |
|---|---|---|
| Channel server probe | `0` | `active_channel_servers` |
| Presence probe | `0` | `presence` |
| Queue probe | `%{"default" => 0, "notifications" => 0, "embeddings" => 0, "link_previews" => 0}` or equivalent JSON object with those exact keys and zero values | `queues` |

The queue fallback shape is fixed for the MVP and must use the same keys as the success contract.

---

## 7. Required Negative Tests

These tests must exist before the MVP is considered done:

- unauthenticated `resources/read` request is denied
- invalid token `resources/read` request is denied
- revoked token `resources/read` request is denied
- unauthenticated `resources/list` request is denied
- revoked token `resources/list` request is denied
- `resources/list` exposes exactly one new MVP resource: `tenun:///ops/summary`
- resource payload contains no Elixir inspection strings
- exact JSON shape is asserted on success
- exact JSON shape is asserted for channel-server probe fallback
- exact JSON shape is asserted for presence probe fallback
- exact JSON shape is asserted for queue probe fallback
- exact `partial_failures` values are asserted
- presence probe failure yields shaped JSON plus sanitized warning logs
- queue probe failure yields shaped JSON plus sanitized warning logs
- the resource remains read-only and cannot mutate system state

---

## 8. Decision Record

### Why v1 is intentionally small

The roadmap wants agents to query system state directly, but the current MCP auth model is coarse and the current observability proxies are limited. The safest path is to ship one low-sensitivity aggregate snapshot, validate that it is useful, and only then consider broader operational or factory visibility.

### Revisit triggers

This document must be revisited if any of the following happen:

- new ops resources are added
- feature flags are proposed for exposure
- factory read resources are proposed
- MCP gains scoped or capability-based tokens
- the snapshot starts including higher-sensitivity data
