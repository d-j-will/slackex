# Prioritization: Incoming Webhooks

## Release Priority

| Priority | Release | Target Outcome | Rationale |
|----------|---------|---------------|-----------|
| 1 | Walking Skeleton | External service can POST a message that appears in a Slackex channel from a bot user | Validates the core assumption: can Slackex replace Discord for deploy notifications? Thinnest possible end-to-end proof. |
| 2 | Release 1: Production-Ready | Dave confidently uses Slackex webhooks daily; Discord webhook removed | Adds the CRUD UI, rate limiting, and error handling needed for real daily use. |
| 3 | Release 2: Management Polish | Dave can self-service webhook lifecycle without touching the database | Token regeneration, usage tracking, auto-create channel. Nice-to-have for a solo developer who can query the DB directly. |

## Scoring

| Release | Value (1-5) | Urgency (1-5) | Effort (1-5) | Score (V*U/E) | Notes |
|---------|-------------|---------------|--------------|---------------|-------|
| Walking Skeleton | 5 | 5 | 2 | 12.5 | Core value prop; small scope; immediate dogfooding |
| Release 1 | 4 | 3 | 3 | 4.0 | Needed for ongoing use; moderate scope |
| Release 2 | 2 | 1 | 2 | 1.0 | Nice-to-have; solo dev can work around missing UI |

## Backlog Suggestions

| Story | Release | Priority | Outcome Link | Dependencies |
|-------|---------|----------|-------------|--------------|
| US-01: Bot User Identity | WS | P1 | Skeleton | None |
| US-02: Webhook Delivery Endpoint | WS | P1 | Skeleton | US-01 |
| US-03: Bot Message Display | WS | P1 | Skeleton | US-01 |
| US-04: Webhook Creation UI | R1 | P2 | Production-Ready | US-01, US-02 |
| US-05: Webhook Delivery Hardening | R1 | P2 | Production-Ready | US-02 |
| US-06: Webhook Management | R2 | P3 | Management Polish | US-04 |

> **Note**: Story IDs (US-01 through US-06) are assigned below in the user stories.
> This table should be revisited after stories are finalized.

## Riskiest Assumptions

| # | Assumption | Risk | How Walking Skeleton Validates |
|---|-----------|------|-------------------------------|
| 1 | Bot messages can flow through the existing Messaging pipeline without changes | HIGH | Walking Skeleton creates a message with a bot sender_id and verifies PubSub broadcast works |
| 2 | Bot user can send messages to a channel (permission check passes) | HIGH | Walking Skeleton subscribes bot user to channel and sends a message through ChannelServer |
| 3 | Webhook URL with embedded token is sufficient auth for external services | LOW | Walking Skeleton tests with curl and GitHub Actions |
| 4 | Markdown rendering works for webhook payloads | LOW | Walking Skeleton uses existing Markdown pipeline (already shipped) |
