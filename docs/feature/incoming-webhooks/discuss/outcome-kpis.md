# Outcome KPIs: Incoming Webhooks

## Feature: Incoming Webhooks

### Objective

Slackex can receive notifications from external services via HTTP webhooks, replacing the Discord webhook dependency and enabling Dave to dogfood his own chat application for all automated notifications.

### Outcome KPIs

| # | Who | Does What | By How Much | Baseline | Measured By | Type |
|---|-----|-----------|-------------|----------|-------------|------|
| 1 | Dave (admin) | Routes deploy notifications through Slackex instead of Discord | 100% of deploy notifications go to Slackex | 0% -- all notifications go to Discord | ci-deploy.yml config: SLACKEX_WEBHOOK_URL used, DISCORD_WEBHOOK_URL removed | Leading |
| 2 | External services | Successfully deliver messages via webhook POST | 99%+ success rate on valid webhook POSTs (200 responses) | 0% -- no webhook endpoint exists | HTTP response status logs / Prometheus metrics | Leading |
| 3 | Dave (chat user) | Identifies bot messages at a glance without reading content | Under 1 second visual recognition via BOT badge | No distinction -- bot concept doesn't exist | Visual inspection: BOT badge present on all bot messages | Leading |
| 4 | Dave (admin) | Creates and manages webhooks without direct DB access | 100% of webhook CRUD operations via UI | 0% -- no UI exists | Webhook count created via UI vs via DB | Lagging |

### Metric Hierarchy

- **North Star**: Deploy notifications appear in Slackex #deploys channel (KPI #1)
  - This is the "dogfooding moment" -- the feature's reason for existing
- **Leading Indicators**:
  - Webhook endpoint responds 200 to valid POSTs (KPI #2)
  - Bot messages render with BOT badge (KPI #3)
  - Webhook creation flow completes under 60 seconds (KPI #4)
- **Guardrail Metrics**:
  - Regular message delivery latency must not increase (webhook processing must not block normal message pipeline)
  - No new error classes in production logs from webhook processing
  - Rate limiting prevents channel flooding (max 60 messages/minute per webhook)

### Measurement Plan

| KPI | Data Source | Collection Method | Frequency | Owner |
|-----|------------|-------------------|-----------|-------|
| Deploy notifs in Slackex | ci-deploy.yml + #deploys channel | Check #deploys after each deploy | Per deploy | Dave |
| Webhook success rate | Application logs / Prometheus | Count 200 vs 4xx/5xx responses on /api/webhooks/:token | Continuous | Observability stack |
| BOT badge rendering | Visual inspection | Check message list after webhook delivery | Per feature test | Dave |
| Webhook CRUD via UI | Application usage | Count webhooks created via UI | Weekly | Dave |

### Hypothesis

We believe that adding an incoming webhook endpoint with bot user identity and a management UI for Dave Williams will achieve the replacement of Discord as the deploy notification channel.

We will know this is true when 100% of deploy notifications appear in the Slackex #deploys channel from a bot user, and Dave has removed the DISCORD_WEBHOOK_URL secret from GitHub Actions.
