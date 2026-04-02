# Agent-Observable Ops Hardening: v1 vs v2 Decision Memo

## Decision

Use `docs/plans/2026-04-02-agent-observable-ops-hardening-plan-v2.md` as the execution plan for the next phase.

Retain `docs/plans/2026-04-02-agent-observable-ops-hardening-plan.md` as the broader original concept document.

Supporting contract doc:

- `docs/plans/2026-04-02-agent-observable-ops-hardening-auth-matrix.md`

---

## Why v1 Was Not Chosen

The original plan had the right strategic direction but was too broad for a safe first slice.

Main problems in v1:

- it expanded MCP visibility before defining an authorization boundary
- it proposed several new resources at once, including factory read resources
- it used field names that overstated what the runtime probes actually mean
- it mixed a proof-of-value goal with a broader platform-shaping goal
- it risked coupling core modules too tightly to transport concerns too early

In short, v1 was a good exploration of the space, but not yet a precise implementation plan.

---

## Why v2 Was Chosen

v2 keeps the same strategic intent while reducing risk.

What v2 improves:

- defines the auth matrix and payload contract before implementation
- limits the MVP to one read-only MCP resource: `tenun:///ops/summary`
- uses accurate field names like `lobby_presence_count` and `queue_running_counts`
- hardens telemetry failure visibility before building on top of those probes
- proves one deterministic dogfood loop instead of trying to prove the entire agent-ops future in one phase

This makes v2 smaller, safer, and easier to validate.

---

## What We Are Deferring

The following ideas remain valid, but are intentionally deferred until after the MVP proves useful:

- queue detail resources
- factory run and factory event MCP resources
- broader auth or capability models for MCP tokens
- richer agent-facing operational read surfaces
- claims that the system is fully agent-queryable from an observability perspective

---

## Success Condition For The Revision

The revision is successful if Slackex gains a small, trustworthy, low-sensitivity MCP ops snapshot that an authenticated agent can read and report on, and if that work clarifies whether it is worth expanding the agent-observable surface further.

If the MVP is noisy, misleading, or not useful in practice, we should stop and rethink before adding more MCP operational resources.
