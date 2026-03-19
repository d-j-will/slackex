# Journey: Webhook Delivery

## Persona

**GitHub Actions CI** -- an external service (non-human actor) that POSTs JSON payloads to Slackex after a deploy completes or fails.

**Dave Williams** -- solo developer who sees the resulting message appear in real-time in the #deploys channel.

## Goal

An external service sends an HTTP POST to the webhook URL. Slackex validates the token, creates a message from the bot user, and broadcasts it via PubSub so it appears instantly in the channel for all connected users.

## Emotional Arc (Dave, the reader)

```
Unaware ──────> Informed ──────> Satisfied
"Working on     "Deploy notif    "I see it right
 something      just appeared    here in my own
 else"          in #deploys"     app, no Discord"
```

## Journey Flow

```
[Trigger]              [Step 1]              [Step 2]              [Step 3]
GitHub Actions         Slackex receives      Message created       Message appears
deploy completes,      POST at               from bot user,        in real-time for
POSTs to webhook URL   /api/webhooks/:token  persisted to DB       all channel members
                       |                     |                     |
Actor: CI              Actor: Slackex        Actor: Slackex        Actor: Dave (reader)
Feels: N/A (machine)   Validates token       Generates Snowflake   Sees: bot message
Sees: HTTP response    Looks up webhook      ID, inserts message,  with markdown
                       config                broadcasts PubSub     rendered content
```

## Step Details

### Step 1: Receive and Validate Webhook POST

External service sends HTTP POST to `/api/webhooks/:token`.

```
POST /api/webhooks/whk_a1b2c3d4e5f6 HTTP/1.1
Content-Type: application/json

{
  "text": "**Deployed: v0.5.80**\n\n**Repo:** davewil/slackex\n**Branch:** master\n**Commit:** `af0b077` -- fix(test): gracefully shutdown ChannelServers\n**Run:** [View logs](https://github.com/davewil/slackex/actions/runs/12345)"
}
```

Slackex performs validation:

```
+-- Webhook Validation Pipeline --------------------------------+
|                                                                |
|  1. Extract token from URL path                               |
|  2. Look up webhook by token (hashed comparison)              |
|  3. Check webhook is active (not revoked)                     |
|  4. Rate limit check (per-webhook, per-IP)                    |
|  5. Validate payload (JSON, has "text" field, size limit)     |
|                                                                |
|  All pass? -> 200 OK + create message                         |
|  Any fail? -> 4xx with error JSON                             |
+----------------------------------------------------------------+
```

**Responses:**

| Status | Condition | Body |
|--------|-----------|------|
| `200 OK` | Message delivered | `{"ok": true}` |
| `400 Bad Request` | Missing/invalid JSON, missing "text" | `{"ok": false, "error": "missing_text_field"}` |
| `401 Unauthorized` | Invalid or revoked token | `{"ok": false, "error": "invalid_token"}` |
| `413 Payload Too Large` | Body exceeds 16KB | `{"ok": false, "error": "payload_too_large"}` |
| `429 Too Many Requests` | Rate limit exceeded | `{"ok": false, "error": "rate_limited"}` + `Retry-After` header |

### Step 2: Create Message from Bot User

After validation, Slackex creates a message in the target channel using the bot user associated with the webhook.

```
+-- Message Creation Pipeline ----------------------------------+
|                                                                |
|  1. Resolve bot user from webhook config                      |
|  2. Generate Snowflake ID                                     |
|  3. Apply optional username override from payload             |
|  4. Insert message (sender_id = bot_user.id)                  |
|     - content: payload "text" (stored encrypted)              |
|     - search_content: plaintext for FTS                       |
|     - channel_id: from webhook config                         |
|  5. Broadcast PubSub envelope: "message.new"                  |
|                                                                |
+----------------------------------------------------------------+
```

**Shared artifacts consumed**:
- `${webhook.channel_id}` -- target channel
- `${webhook.bot_user_id}` -- sender identity
- `${payload.text}` -- message content (markdown)
- `${payload.username}` -- optional display name override

### Step 3: Message Appears in Real-Time

Dave has the #deploys channel open. The message appears instantly via PubSub, rendered with markdown formatting.

```
+------------------------------------------------------------------+
| #deploys                                                          |
+------------------------------------------------------------------+
|                                                                    |
|  -- Today, March 19 --                                             |
|                                                                    |
|  [BOT] Deploy Bot                              2:34 PM            |
|  +------------------------------------------------------------+   |
|  | Deployed: v0.5.80                                           |   |
|  |                                                             |   |
|  | Repo: davewil/slackex                                       |   |
|  | Branch: master                                              |   |
|  | Commit: af0b077 -- fix(test): gracefully shutdown           |   |
|  |         ChannelServers                                      |   |
|  | Run: View logs                                              |   |
|  +------------------------------------------------------------+   |
|                                                                    |
|  [BOT] Deploy Bot                              2:33 PM            |
|  +------------------------------------------------------------+   |
|  | CI Failed: Quality                                          |   |
|  |                                                             |   |
|  | Repo: davewil/slackex                                       |   |
|  | Branch: master                                              |   |
|  | Commit: ba0db06 -- fix(ci): use --only e2e instead of       |   |
|  |         --include e2e in CI                                 |   |
|  | Run: View logs                                              |   |
|  +------------------------------------------------------------+   |
|                                                                    |
+------------------------------------------------------------------+
```

**Emotional state**: Satisfied. Bot messages are visually distinct (BOT badge), markdown is rendered, links are clickable. Dave sees deploy status without leaving Slackex.

## Error Paths

| Error | When | External Service Sees | Recovery |
|-------|------|----------------------|----------|
| Invalid token | Token not found or revoked | `401 {"ok": false, "error": "invalid_token"}` | Check webhook URL, regenerate if needed |
| Malformed JSON | Body is not valid JSON | `400 {"ok": false, "error": "invalid_json"}` | Fix payload format |
| Missing text | JSON has no "text" field | `400 {"ok": false, "error": "missing_text_field"}` | Add "text" field to payload |
| Payload too large | Body exceeds 16KB | `413 {"ok": false, "error": "payload_too_large"}` | Reduce payload size |
| Rate limited | Too many requests from this webhook | `429 {"ok": false, "error": "rate_limited"}` + Retry-After | Wait and retry |
| Channel deleted | Target channel was deleted after webhook created | `404 {"ok": false, "error": "channel_not_found"}` | Reconfigure webhook |

## Integration Points

| From | To | Data | Mechanism |
|------|-----|------|-----------|
| HTTP POST | Webhook controller | Raw JSON payload | Phoenix router + controller |
| Webhook controller | Messaging context | channel_id, bot_user_id, content | `Messaging.send_message/4` or dedicated function |
| Messaging context | PubSub | Envelope with "message.new" event | `Phoenix.PubSub.broadcast/3` |
| PubSub | LiveView | Message appears in channel | `handle_info({:envelope, _})` |
| Message content | Markdown renderer | Raw text to HTML | `Slackex.Markdown.to_html/1` (feature-flagged) |
