# Story Map: Incoming Webhooks

## User: Dave Williams (solo developer)

## Goal: Route external service notifications into Slackex channels via incoming webhooks

## Backbone

| Schema + Bot Identity | Webhook CRUD | Webhook Delivery | Bot Message Display | CI Integration |
|----------------------|--------------|------------------|--------------------|--------------------|
| Add `is_bot` to User | Create webhook | Receive POST | BOT badge on messages | Update ci-deploy.yml |
| Bot user creation | List webhooks | Validate token | Markdown rendering | Add GH secret |
| Bot channel subscription | View webhook details | Rate limiting | Username override display | |
| | Regenerate token | Payload validation | Bot messages in search | |
| | Delete webhook | Auto-create channel | | |
| | Webhook management UI | Error responses | | |

---

### Walking Skeleton

The thinnest end-to-end slice that proves the concept works:

1. **Schema + Bot Identity**: Add `is_bot` field to User schema. Create a bot user manually or via seed.
2. **Webhook CRUD**: Create a webhook record (channel_id, bot_user_id, hashed token) -- can be a simple DB insert, no UI needed yet.
3. **Webhook Delivery**: Phoenix controller at `/api/webhooks/:token` that validates token, creates message from bot user, broadcasts via PubSub.
4. **Bot Message Display**: Message component shows `[BOT]` badge when `sender.is_bot` is true.
5. **CI Integration**: Replace Discord webhook URL in ci-deploy.yml with Slackex webhook URL.

This skeleton is intentionally thin: no webhook management UI, no regeneration, no rate limiting. Just enough to prove messages flow from GitHub Actions into Slackex.

### Release 1: Production-Ready Webhooks

Target outcome: Dave confidently uses Slackex webhooks for all deploy notifications, Discord webhook removed.

- **Schema + Bot Identity**: Bot user creation as part of webhook setup (automated, not manual)
- **Webhook CRUD**: Create webhook UI (form with channel selector, display name, description), webhook list page, delete webhook
- **Webhook Delivery**: Rate limiting (per-webhook), payload validation (size limit, required fields), error responses with structured JSON
- **Bot Message Display**: Username override from payload, bot avatar distinct from regular users
- **CI Integration**: (completed in Walking Skeleton)

### Release 2: Webhook Management Polish

Target outcome: Dave can manage webhooks confidently -- regenerate tokens, see usage, handle edge cases.

- **Webhook CRUD**: Regenerate token, webhook detail view with last-used timestamp
- **Webhook Delivery**: Auto-create channel if it doesn't exist, handle deleted channel gracefully
- **Bot Message Display**: Bot messages appear in search results with BOT badge
- **Schema + Bot Identity**: (completed)
- **CI Integration**: (completed)
