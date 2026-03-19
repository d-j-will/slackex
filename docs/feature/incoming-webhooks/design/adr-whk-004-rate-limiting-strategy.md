# ADR-WHK-004: Webhook Rate Limiting Strategy

## Status

Accepted

## Context

Webhook endpoints need rate limiting to prevent channel flooding from misconfigured CI pipelines or abuse. The existing codebase has two rate limiting mechanisms:

1. **`SlackexWeb.Plugs.RateLimit`**: Redis-backed (INCR + EXPIRE), per-IP keying, used on auth endpoints. Fails open on Redis unavailability.
2. **`Slackex.Infrastructure.RateLimiter`**: In-memory token bucket, per-user keying, used inside ChannelServer for message send rate (10/second).

The webhook rate limit requirement is: 60 requests per 60-second rolling window, keyed per webhook (not per IP and not per user).

## Decision

Redis-backed rate limiting keyed by webhook ID, reusing the same Redis infrastructure and INCR + EXPIRE pattern as the existing `SlackexWeb.Plugs.RateLimit`.

- Key: `webhook_rate:{webhook_id}`
- Window: 60 seconds
- Limit: 60 requests (configurable)
- Fail-open: if Redis is unavailable, requests are allowed through
- Response: HTTP 429 with `Retry-After` header and `{"ok": false, "error": "rate_limited"}`
- Placement: checked in the controller after token lookup (need webhook ID for the key) but before message creation

## Alternatives Considered

### Alternative A: In-memory rate limiting via `RateLimiter` (token bucket)

Use the existing `Slackex.Infrastructure.RateLimiter` module with per-webhook keying, stored in the controller process or an ETS table.

**Evaluation:**
- (+) No Redis dependency for rate limiting
- (+) Faster (no network round-trip)
- (-) Not distributed: rate limits are per-node in a multi-node cluster. Slackex already runs multi-node (see project memory: "Already running multi-node"). A webhook could get 60 req/min per node.
- (-) State lost on process restart
- (-) Would need a new GenServer or ETS table to hold per-webhook state

**Rejected because:** Slackex runs multi-node. In-memory rate limiting would allow N * 60 requests per minute across N nodes. Redis provides a single shared counter.

### Alternative B: Per-IP rate limiting (reuse existing plug directly)

Use `SlackexWeb.Plugs.RateLimit` as-is with IP-based keying on the webhook route.

**Evaluation:**
- (+) Zero new code -- just add the plug to the pipeline
- (+) Protects against distributed attacks from many IPs
- (-) Wrong semantic: the rate limit should be per-webhook, not per-IP. A single CI server using multiple webhooks would share one rate limit. Multiple CI servers using the same webhook would each get their own limit.
- (-) Cannot differentiate between webhooks -- one flooding webhook blocks others from the same IP

**Rejected because:** Per-IP keying has the wrong granularity. The requirement is to prevent any single webhook from flooding its target channel, regardless of source IP. A GitHub Actions runner IP might be shared across many webhooks.

## Consequences

### Positive

- **Correct granularity**: Each webhook has its own independent rate limit.
- **Distributed correctness**: Single Redis counter works across all nodes.
- **Proven pattern**: Same INCR + EXPIRE approach already battle-tested on auth endpoints.
- **Fail-open**: Redis outage does not block webhook delivery (matches existing pattern and project convention).

### Negative

- **Redis dependency**: Rate limiting depends on Redis availability. Accepted risk: fail-open behavior means Redis outage = temporarily unlimited webhooks, which is acceptable for a homelab application with a 60/min limit.
- **Not a plug reuse**: Cannot directly reuse the existing `RateLimit` plug because the keying strategy differs (webhook ID vs IP). The pattern is reused but the implementation requires a new function or adapted plug.
- **Double rate limiting**: Webhook messages pass through both the controller-level webhook rate limit (60/min) and the ChannelServer's per-user rate limit (10/second = 600/min). The controller limit is the binding constraint. No conflict since 60/min << 600/min.
