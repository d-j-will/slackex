# Definition of Ready Validation: Incoming Webhooks

## Story: US-01 -- Bot User Identity

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "Without a bot identity, webhook messages would either have no sender (confusing) or impersonate a real user (misleading)" -- domain language, specific pain |
| User/persona identified | PASS | Dave Williams, solo developer running Slackex on homelab |
| 3+ domain examples | PASS | 3 examples: bot creation, coexistence with Maria Santos, login rejection |
| UAT scenarios (3-7) | PASS | 3 scenarios: creation, auth rejection, member list visibility |
| AC derived from UAT | PASS | 4 AC items, each traceable to scenarios |
| Right-sized | PASS | 1 day effort, 3 scenarios, single migration + changeset |
| Technical notes | PASS | Migration details, changeset guidance, JSON encoder note |
| Dependencies tracked | PASS | None (foundational story) |
| Outcome KPIs defined | PASS | "100% of webhook messages display BOT badge" |

### DoR Status: PASSED

---

## Story: US-02 -- Webhook Delivery Endpoint

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "Slackex has no HTTP endpoint that external services can POST to" -- specific gap, domain language |
| User/persona identified | PASS | External service (GitHub Actions CI), automated HTTP client |
| 3+ domain examples | PASS | 5 examples: deploy notification, username override, invalid token, missing text, oversized payload |
| UAT scenarios (3-7) | PASS | 5 scenarios covering happy path, PubSub, invalid token, missing field, oversized payload |
| AC derived from UAT | PASS | 8 AC items, each traceable to scenarios |
| Right-sized | PASS | 2-3 days effort, 5 scenarios, controller + route + message pipeline |
| Technical notes | PASS | Route definition, token lookup strategy, message creation approach, body size enforcement |
| Dependencies tracked | PASS | Depends on US-01 (documented) |
| Outcome KPIs defined | PASS | "100% of valid webhook POSTs result in a message appearing in the target channel" |

### DoR Status: PASSED

---

## Story: US-03 -- Bot Message Display

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "Without visual distinction, bot messages look identical to human messages" -- user pain in domain language |
| User/persona identified | PASS | Dave Williams, chat user reading messages in a channel |
| 3+ domain examples | PASS | 3 examples: BOT badge, interleaved messages, username override |
| UAT scenarios (3-7) | PASS | 3 scenarios: badge display, no badge on human, thread panel |
| AC derived from UAT | PASS | 5 AC items traceable to scenarios |
| Right-sized | PASS | 1 day effort, 3 scenarios, component conditional rendering |
| Technical notes | PASS | Preload requirement, Envelope serialization, component conditional, styling guidance |
| Dependencies tracked | PASS | Depends on US-01 (documented) |
| Outcome KPIs defined | PASS | "Identification in under 1 second (visual badge vs reading sender name)" |

### DoR Status: PASSED

---

## Story: US-04 -- Webhook Creation UI

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "Without a UI, he would need to insert records directly into the database, generate tokens manually" -- specific pain |
| User/persona identified | PASS | Dave Williams, admin setting up integrations |
| 3+ domain examples | PASS | 4 examples: existing channel, auto-create channel, invalid name, default display name |
| UAT scenarios (3-7) | PASS | 5 scenarios: create for existing, auto-create, validation error, list view, delete |
| AC derived from UAT | PASS | 7 AC items traceable to scenarios |
| Right-sized | PASS | 2-3 days effort, 5 scenarios, LiveView page with form + list + confirmation |
| Technical notes | PASS | Route suggestion, token generation approach, hashing strategy |
| Dependencies tracked | PASS | Depends on US-01, US-02 (documented) |
| Outcome KPIs defined | PASS | "Webhook creation time under 60 seconds (vs minutes of manual DB work)" |

### DoR Status: PASSED

---

## Story: US-05 -- Webhook Delivery Hardening

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "Without rate limiting, a misconfigured CI job could flood a channel" -- specific risk, domain language |
| User/persona identified | PASS | Dave Williams, admin operating webhooks in production |
| 3+ domain examples | PASS | 3 examples: rate limit enforced, structured error for debugging, oversized payload |
| UAT scenarios (3-7) | PASS | 3 scenarios: rate limit threshold, rate limit reset, invalid JSON |
| AC derived from UAT | PASS | 5 AC items traceable to scenarios |
| Right-sized | PASS | 1-2 days effort, 3 scenarios, plug additions to existing endpoint |
| Technical notes | PASS | Redis-backed rate limiting, Plug.Parsers length option |
| Dependencies tracked | PASS | Depends on US-02 (documented) |
| Outcome KPIs defined | PASS | "Zero unhandled error cases; all failures return actionable error codes" |

### DoR Status: PASSED

---

## Story: US-06 -- Webhook Management

| DoR Item | Status | Evidence/Issue |
|----------|--------|----------------|
| Problem statement clear | PASS | "If a webhook token is compromised, he needs to regenerate it without deleting and recreating" -- specific scenario |
| User/persona identified | PASS | Dave Williams, admin managing webhooks over time |
| 3+ domain examples | PASS | 3 examples: regenerate compromised token, last-used timestamp, deleted channel |
| UAT scenarios (3-7) | PASS | 3 scenarios: regenerate token, last-used update, deleted channel handling |
| AC derived from UAT | PASS | 4 AC items traceable to scenarios |
| Right-sized | PASS | 1-2 days effort, 3 scenarios, additions to existing webhook UI |
| Technical notes | PASS | Token regeneration approach, async last-used tracking, channel existence check |
| Dependencies tracked | PASS | Depends on US-04 (documented) |
| Outcome KPIs defined | PASS | "Token regeneration in under 30 seconds" |

### DoR Status: PASSED

---

## Overall Validation

All 6 stories pass all 9 DoR items. Ready for handoff to DESIGN wave.

| Story | DoR Status | Estimated Effort | Release |
|-------|-----------|-----------------|---------|
| US-01: Bot User Identity | PASSED | 1 day | Walking Skeleton |
| US-02: Webhook Delivery Endpoint | PASSED | 2-3 days | Walking Skeleton |
| US-03: Bot Message Display | PASSED | 1 day | Walking Skeleton |
| US-04: Webhook Creation UI | PASSED | 2-3 days | Release 1 |
| US-05: Webhook Delivery Hardening | PASSED | 1-2 days | Release 1 |
| US-06: Webhook Management | PASSED | 1-2 days | Release 2 |
