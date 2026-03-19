# Journey: Webhook Setup

## Persona

**Dave Williams** -- solo developer running Slackex on a homelab. Currently sends deploy notifications to Discord. Wants to dogfood Slackex by routing external service notifications into his own chat app.

## Goal

Create a webhook endpoint so external services (starting with GitHub Actions) can POST messages into a specific Slackex channel, appearing from a bot user with rich markdown formatting.

## Emotional Arc

```
Curious/Excited ──> Focused ──> Confident ──> Satisfied
"Can I replace     "Setting    "Got the     "It works,
 Discord with      this up"    URL, let me   deploy notifs
 my own app?"                  try it"       are in Slackex"
```

## Journey Flow

```
[Trigger]              [Step 1]              [Step 2]              [Step 3]
Dave wants to          Opens Slackex         Creates a new         Copies webhook
route deploy           admin/settings        webhook, picks        URL and pastes
notifs to Slackex      to manage webhooks    channel + bot name    into GitHub Actions
                       |                     |                     |
Feels: Curious         Feels: Oriented       Feels: Focused        Feels: Confident
Sees: ???              Sees: Webhook list     Sees: Form            Sees: URL + token
                       (empty at first)       with fields           ready to copy
```

## Step Details

### Step 1: Navigate to Webhook Management

Dave navigates to a webhook management area within Slackex. This could be an admin page or a settings section accessible to channel owners/admins.

```
+------------------------------------------------------------------+
| Slackex > Settings > Webhooks                                     |
+------------------------------------------------------------------+
|                                                                    |
|  Incoming Webhooks                                                 |
|  External services can POST messages to Slackex channels.          |
|                                                                    |
|  +------------------------------------------------------------+   |
|  | No webhooks configured yet.                                 |   |
|  | Create your first webhook to receive messages from          |   |
|  | external services like GitHub Actions, CI/CD pipelines,     |   |
|  | or monitoring tools.                                        |   |
|  +------------------------------------------------------------+   |
|                                                                    |
|  [ + Create Webhook ]                                              |
|                                                                    |
+------------------------------------------------------------------+
```

**Emotional state**: Oriented. The empty state explains what webhooks are and gives a clear call to action.

**Shared artifacts**: None yet.

### Step 2: Create a Webhook

Dave fills out a simple form to create a new webhook. He specifies which channel the webhook posts to (auto-created if it doesn't exist) and an optional display name for the bot user.

```
+------------------------------------------------------------------+
| Create Incoming Webhook                                           |
+------------------------------------------------------------------+
|                                                                    |
|  Channel *                                                         |
|  [ #deploys                                          v ]           |
|  Channel will be created if it doesn't exist.                      |
|                                                                    |
|  Display Name                                                      |
|  [ Deploy Bot                                          ]           |
|  Name shown on messages. Defaults to "Webhook".                    |
|                                                                    |
|  Description                                                       |
|  [ GitHub Actions deploy notifications                 ]           |
|  Optional note for your reference.                                 |
|                                                                    |
|                                                                    |
|                              [ Cancel ]  [ Create Webhook ]        |
|                                                                    |
+------------------------------------------------------------------+
```

**Emotional state**: Focused. Minimal fields, clear labels, sensible defaults.

**Shared artifacts produced**:
- `${webhook_token}` -- generated secure token
- `${webhook_url}` -- full URL with embedded token
- `${channel_name}` -- target channel (existing or newly created)
- `${bot_display_name}` -- display name for the bot user

### Step 3: Copy Webhook URL

After creation, Dave sees the webhook URL with the embedded token. He copies it for use in GitHub Actions.

```
+------------------------------------------------------------------+
| Webhook Created                                                   |
+------------------------------------------------------------------+
|                                                                    |
|  "Deploy Bot" webhook for #deploys is ready.                       |
|                                                                    |
|  Webhook URL:                                                      |
|  +------------------------------------------------------------+   |
|  | https://slackex.example.com/api/webhooks/whk_a1b2c3d4e5f6  |   |
|  +------------------------------------------------------------+   |
|  [ Copy URL ]                                                      |
|                                                                    |
|  Send a test message:                                              |
|                                                                    |
|    curl -X POST \                                                  |
|      -H "Content-Type: application/json" \                         |
|      -d '{"text": "Hello from webhook!"}' \                        |
|      https://slackex.example.com/api/webhooks/whk_a1b2c3d4e5f6     |
|                                                                    |
|  +------------------------------------------------------------+   |
|  | (!) Save this URL -- the token cannot be viewed again       |   |
|  |     after leaving this page.                                |   |
|  +------------------------------------------------------------+   |
|                                                                    |
|  Payload format:                                                   |
|  {                                                                 |
|    "text": "**Deploy v0.5.80** completed successfully",            |
|    "username": "CI Bot"       // optional, overrides display name  |
|  }                                                                 |
|                                                                    |
|  The "text" field supports markdown formatting.                    |
|                                                                    |
|                                                 [ Done ]           |
+------------------------------------------------------------------+
```

**Emotional state**: Confident. Dave has everything he needs -- URL, curl example, payload format. The warning about token visibility creates healthy urgency to copy now.

**Shared artifacts consumed**:
- `${webhook_url}` -- displayed for copying
- `${webhook_token}` -- embedded in URL (shown once)
- `${bot_display_name}` -- shown in confirmation
- `${channel_name}` -- shown in confirmation

## Error Paths

| Error | When | User Sees | Recovery |
|-------|------|-----------|----------|
| Channel name invalid | Step 2: name has invalid characters | Inline validation: "Channel names can only contain lowercase letters, numbers, and hyphens" | Fix the name |
| Channel name too long | Step 2: name exceeds 100 chars | Inline validation: "Channel name must be 100 characters or fewer" | Shorten the name |
| Duplicate webhook | Step 2: same channel + same name | "A webhook with this name already exists for #deploys" | Choose different name |
| Token lost | Step 3: user navigates away without copying | Cannot retrieve token; must regenerate | Delete and recreate, or use "Regenerate Token" |

## Integration Points

| From | To | Data |
|------|-----|------|
| Webhook creation | User schema | Bot user created with `is_bot: true` |
| Webhook creation | Channel schema | Channel auto-created if missing, bot user subscribed |
| Webhook creation | Webhook schema | Token stored (hashed), channel_id, bot_user_id |
| Webhook URL | GitHub Actions | `SLACKEX_WEBHOOK_URL` secret |
