<!-- markdownlint-disable MD024 -->

# Incoming Webhooks -- User Stories

## US-01: Bot User Identity

### Problem

Dave Williams is a solo developer building Slackex. When external services send messages via webhooks, those messages need a sender identity that is visually distinct from regular human users. Without a bot identity, webhook messages would either have no sender (confusing) or impersonate a real user (misleading). Dave needs bot messages to be immediately recognizable as automated.

### Who

- Solo developer / admin | Running Slackex on homelab | Wants automated messages visually distinct from human messages

### Solution

Add an `is_bot` boolean field to the User schema so that bot users can be created for webhook senders. Bot users do not have passwords or emails -- they exist solely as message sender identities.

### Domain Examples

#### 1: Happy Path -- Create bot user for deploy notifications

Dave creates a bot user named "Deploy Bot" with `is_bot: true`. The bot user has a display_name of "Deploy Bot", no email, no password. The bot user is assigned to a webhook that posts to #deploys.

#### 2: Edge Case -- Bot user coexists with regular users

Maria Santos registers as a regular user with username "maria.santos". The bot user "Deploy Bot" exists alongside Maria in the users table. Maria's messages show her avatar; Deploy Bot's messages show a BOT badge. They can both be members of #deploys.

#### 3: Boundary -- Bot user cannot log in

An attacker tries to log in as "deploy-bot" via the login page. Because the bot user has no hashed_password, `User.valid_password?/2` returns false. The bot user is not accessible through authentication flows.

### UAT Scenarios (BDD)

#### Scenario: Bot user creation

Given Dave is setting up a new webhook
When a bot user is created with display_name "Deploy Bot" and is_bot set to true
Then the user record exists in the database with is_bot true
And the bot user has no hashed_password
And the bot user has no email

#### Scenario: Bot user cannot authenticate

Given a bot user "deploy-bot" exists with is_bot true
When someone attempts to log in with username "deploy-bot" and any password
Then authentication fails
And no session is created

#### Scenario: Bot user visible in channel member list

Given the bot user "Deploy Bot" is subscribed to "#deploys"
When Dave views the member list of "#deploys"
Then "Deploy Bot" appears in the member list with a BOT indicator

### Acceptance Criteria

- [ ] User schema has `is_bot` boolean field (default false)
- [ ] Bot users can be created without email or password
- [ ] Bot users cannot authenticate via login flows
- [ ] Bot users can be subscribed to channels

### Outcome KPIs

- **Who**: Dave (admin)
- **Does what**: Creates bot users that are visually distinguishable from human users
- **By how much**: 100% of webhook messages display BOT badge
- **Measured by**: Visual inspection of message list
- **Baseline**: No bot user concept exists

### Technical Notes

- Migration: add `is_bot` boolean column to `users` table, default `false`, null `false`
- Bot user creation needs a dedicated changeset (no email/password validation)
- Existing `registration_changeset` must not be used for bot users
- The `is_bot` field must be included in `Jason.Encoder` derive list for API/PubSub serialization

---

## US-02: Webhook Delivery Endpoint

### Problem

Dave Williams wants external services like GitHub Actions to send notifications into Slackex channels. Currently, deploy notifications go to Discord because Slackex has no HTTP endpoint that external services can POST to. Dave needs a simple, unauthenticated-by-session endpoint that accepts JSON payloads and creates messages in the right channel from a bot user.

### Who

- External service (GitHub Actions CI) | Automated HTTP client | Sends JSON payloads after events like deploys

### Solution

A Phoenix controller at `/api/webhooks/:token` that validates the token, extracts the message text from the JSON payload, and creates a message in the webhook's configured channel from the webhook's bot user.

### Domain Examples

#### 1: Happy Path -- GitHub Actions deploy notification

GitHub Actions completes a deploy of v0.5.81. The CI notify job POSTs to `https://slackex.nerdwerks.net/api/webhooks/whk_a1b2c3d4e5f6` with body `{"text": "**Deployed: v0.5.81**\n\n**Repo:** davewil/slackex\n**Commit:** `07c9eb7`"}`. Slackex responds `{"ok": true}`. The message appears in #deploys from "Deploy Bot" with rendered markdown.

#### 2: Edge Case -- POST with username override

A monitoring tool POSTs to the same webhook URL with `{"text": "CPU usage at 95%", "username": "Monitor Alert"}`. The message appears in #deploys but shows "Monitor Alert" as the sender name instead of "Deploy Bot" for this single message.

#### 3: Error Path -- Invalid token

An attacker guesses a webhook URL and POSTs to `/api/webhooks/whk_fake_token_123`. Slackex looks up the hashed token, finds no match, and responds with `401 {"ok": false, "error": "invalid_token"}`. No message is created, no information is leaked about valid tokens.

#### 4: Error Path -- Missing text field

A misconfigured service POSTs `{"message": "hello"}` (wrong field name) to a valid webhook URL. Slackex responds with `400 {"ok": false, "error": "missing_text_field"}`. The error message tells the caller exactly what field is expected.

#### 5: Error Path -- Payload too large

A runaway script POSTs a 50KB JSON body to a webhook. Slackex rejects it with `413 {"ok": false, "error": "payload_too_large"}` before attempting to parse or store the content.

### UAT Scenarios (BDD)

#### Scenario: Successful delivery creates message

Given a webhook exists for "#deploys" with token "whk_a1b2c3d4e5f6" and bot user "Deploy Bot"
When GitHub Actions POSTs `{"text": "**Deployed: v0.5.81**"}` to /api/webhooks/whk_a1b2c3d4e5f6
Then the response is 200 with body `{"ok": true}`
And a message with content "**Deployed: v0.5.81**" exists in "#deploys"
And the message sender is the "Deploy Bot" bot user
And the message has a valid Snowflake ID

#### Scenario: Message broadcast via PubSub

Given Dave is subscribed to the "#deploys" PubSub topic
When a webhook delivers a message to "#deploys"
Then Dave receives a PubSub envelope with event "message.new"
And the envelope payload includes the message content and bot user info

#### Scenario: Invalid token rejected

When a POST is sent to /api/webhooks/whk_nonexistent_token with `{"text": "test"}`
Then the response is 401 with body containing "invalid_token"
And no message is created in any channel

#### Scenario: Missing text field rejected

Given a webhook exists with token "whk_a1b2c3d4e5f6"
When a POST is sent to /api/webhooks/whk_a1b2c3d4e5f6 with `{"username": "bot"}`
Then the response is 400 with body containing "missing_text_field"

#### Scenario: Oversized payload rejected

Given a webhook exists with token "whk_a1b2c3d4e5f6"
When a POST with a 20KB body is sent to /api/webhooks/whk_a1b2c3d4e5f6
Then the response is 413 with body containing "payload_too_large"

### Acceptance Criteria

- [ ] POST to `/api/webhooks/:token` with valid token and `{"text": "..."}` creates a message in the configured channel
- [ ] Message is created from the webhook's bot user (sender_id = bot_user_id)
- [ ] Message content is encrypted (Cloak) and search_content is populated (plaintext)
- [ ] PubSub envelope broadcast on channel topic (same as regular messages)
- [ ] Invalid token returns 401 with structured JSON error
- [ ] Missing/empty text field returns 400 with structured JSON error
- [ ] Payload exceeding 16KB returns 413 with structured JSON error
  - Payload size limit enforced at 16KB via `Plug.Parsers` `:length` option BEFORE JSON decoding runs
  - Must be configured in the Endpoint or a dedicated plug, not after parsing
- [ ] Optional `username` field overrides display name for that message

### Outcome KPIs

- **Who**: External services (GitHub Actions)
- **Does what**: Successfully deliver messages into Slackex channels via HTTP POST
- **By how much**: 100% of valid webhook POSTs result in a message appearing in the target channel
- **Measured by**: HTTP response status (200 vs error) and message count in channel
- **Baseline**: 0 -- no webhook endpoint exists

### Technical Notes

- Route: `POST /api/webhooks/:token` -- outside authentication pipelines (no session, no JWT)
- Route MUST NOT be nested under any session/JWT/Guardian authentication pipeline
- Token validation via database lookup is the ONLY auth mechanism
- Define route at top-level Router scope with its own minimal pipeline (JSON parsing only)
- Recommended: `scope "/api/webhooks" do ... end` outside any `pipe_through [:api]` that applies auth plugs
- Token lookup: hash the incoming token, compare against stored hash
- Message creation: use `Chat.Messages.send_message/3` or a dedicated function that bypasses role-based permission check (bot user is pre-authorized via webhook config)
- Body size: enforce via Plug.Parsers `:length` option or custom plug
- Depends on: US-01 (bot user identity)

---

## US-03: Bot Message Display

### Problem

Dave Williams receives messages from bot users in his Slackex channels. Without visual distinction, bot messages look identical to human messages, making it hard to tell at a glance which messages are automated notifications versus human conversation. Dave needs bot messages to be immediately recognizable without disrupting the reading flow.

### Who

- Solo developer / chat user | Reading messages in a channel | Needs to distinguish bot messages from human messages at a glance

### Solution

The message display component checks the sender's `is_bot` flag and renders a `[BOT]` badge next to the sender name for bot messages.

### Domain Examples

#### 1: Happy Path -- Bot message with BOT badge

"Deploy Bot" sends a message to #deploys: "**Deployed: v0.5.81**". Dave sees the message with "Deploy Bot" as the sender, a small [BOT] badge next to the name, and the content rendered with markdown bold formatting.

#### 2: Happy Path -- Bot and human messages interleaved

In #deploys, Dave sees:
- [BOT] Deploy Bot: "**Deployed: v0.5.81**" (2:34 PM)
- Maria Santos: "Nice, that was fast!" (2:35 PM)
- [BOT] Deploy Bot: "**CI Failed: Quality**" (3:10 PM)

The BOT badge makes it instantly clear which messages are automated.

#### 3: Edge Case -- Bot message with username override

A webhook delivers a message with `"username": "CI Bot"`. The message shows "CI Bot" as the sender name with the [BOT] badge. The badge comes from the underlying bot user's `is_bot` flag, not the overridden name.

### UAT Scenarios (BDD)

#### Scenario: Bot message shows BOT badge

Given a message from bot user "Deploy Bot" exists in "#deploys"
When Dave views the "#deploys" channel
Then the message shows "Deploy Bot" as the sender
And a "[BOT]" badge appears next to the sender name
And the message content is rendered with markdown formatting

#### Scenario: Human message has no BOT badge

Given a message from regular user "Maria Santos" exists in "#deploys"
When Dave views the "#deploys" channel
Then the message shows "Maria Santos" as the sender
And no "[BOT]" badge appears

#### Scenario: Bot message in thread panel

Given a bot message exists in "#deploys"
When Dave opens a thread containing the bot message
Then the bot message shows the "[BOT]" badge in the thread panel

### Acceptance Criteria

- [ ] Messages from users with `is_bot: true` display a [BOT] badge next to sender name
- [ ] Messages from regular users (is_bot: false) display no badge
- [ ] BOT badge appears in main message list, thread panel, and search results
- [ ] Markdown rendering applies to bot message content (via existing :markdown_rendering feature flag)
- [ ] Bot messages have the same layout (spacing, alignment, timestamp) as regular messages

### Outcome KPIs

- **Who**: Dave (chat user)
- **Does what**: Distinguishes bot messages from human messages without reading content
- **By how much**: Identification in under 1 second (visual badge vs reading sender name)
- **Measured by**: Visual inspection -- BOT badge present on all bot messages, absent on human messages
- **Baseline**: No distinction exists

### Technical Notes

- `is_bot` must be preloaded on `message.sender` (already in sender preload)
- `is_bot` must be included in the Envelope payload for PubSub broadcasts
- Message component conditional: `if @message.sender.is_bot, do: render_bot_badge()`
- BOT badge styling: small, muted label (not distracting) -- consider a rounded pill or chip
- Depends on: US-01 (bot user identity)

---

## US-04: Webhook Creation UI

### Problem

Dave Williams needs to create webhooks to connect external services to Slackex channels. Without a UI, he would need to insert records directly into the database, generate tokens manually, and hash them himself. This is error-prone and unsustainable. Dave needs a simple form where he picks a channel, names the bot, and gets a ready-to-use webhook URL.

### Who

- Solo developer / admin | Setting up integrations | Wants quick, mistake-free webhook creation

### Solution

A webhook management LiveView page with a creation form (channel selector, display name, description), confirmation page showing the URL and curl example, and a list view of existing webhooks.

### Domain Examples

#### 1: Happy Path -- Create webhook for existing channel

Dave navigates to Settings > Webhooks, clicks "Create Webhook". He selects "#deploys" from the channel dropdown, enters "Deploy Bot" as the display name, enters "GitHub Actions deploy notifications" as the description. He clicks "Create Webhook". The confirmation page shows the URL `https://slackex.nerdwerks.net/api/webhooks/whk_7f8g9h0i1j2k` with a copy button and curl example.

#### 2: Happy Path -- Create webhook with auto-created channel

Dave wants a #monitoring channel that doesn't exist yet. He types "monitoring" in the channel field. When he submits, Slackex creates the #monitoring channel and the webhook simultaneously. The confirmation page shows the URL.

#### 3: Error Path -- Invalid channel name

Dave types "My Channel!!!" in the channel field. On submit, he sees inline validation: "Channel names can only contain lowercase letters, numbers, and hyphens." The form is not submitted.

#### 4: Edge Case -- Default display name

Dave creates a webhook but leaves the display name field empty. The bot user is created with display_name "Webhook" (the default). The webhook works identically.

### UAT Scenarios (BDD)

#### Scenario: Create webhook for existing channel

Given Dave is on the Create Webhook page
And the channel "#deploys" exists
When Dave selects "#deploys" as the channel
And Dave enters "Deploy Bot" as the display name
And Dave clicks "Create Webhook"
Then Dave sees a confirmation page with the webhook URL
And the URL contains an embedded token
And Dave sees a curl example using the correct URL
And the webhook appears in the webhook list

#### Scenario: Create webhook with channel auto-creation

Given Dave is on the Create Webhook page
And no channel named "monitoring" exists
When Dave types "monitoring" as the channel name
And Dave clicks "Create Webhook"
Then the "#monitoring" channel is created
And a webhook is created for "#monitoring"
And Dave sees the confirmation page with the webhook URL

#### Scenario: Invalid channel name shows validation error

Given Dave is on the Create Webhook page
When Dave types "Invalid Name!!!" as the channel name
And Dave clicks "Create Webhook"
Then Dave sees an error "Channel names can only contain lowercase letters, numbers, and hyphens"
And no webhook is created

#### Scenario: Webhook list shows existing webhooks

Given Dave has created webhooks "Deploy Bot" for "#deploys" and "Alert Bot" for "#monitoring"
When Dave navigates to the Webhooks settings page
Then Dave sees both webhooks listed
And each entry shows the display name, channel, and creation date

#### Scenario: Delete webhook from list

Given Dave has a webhook "Deploy Bot" for "#deploys"
When Dave clicks delete on the "Deploy Bot" webhook
And Dave confirms the deletion
Then the webhook is removed from the list
And future POSTs to the old URL return 401

### Acceptance Criteria

- [ ] Webhook settings page lists all webhooks with display name, channel, creation date
- [ ] Create form has fields for channel (select or type new), display name (optional), description (optional)
- [ ] Channel auto-created if name entered doesn't match existing channel
- [ ] Confirmation page shows URL once with copy button and curl example
- [ ] Token not retrievable after leaving confirmation page
- [ ] Delete webhook with confirmation dialog
- [ ] Empty state explains what webhooks are with clear call to action

### Outcome KPIs

- **Who**: Dave (admin)
- **Does what**: Creates and manages webhooks through the UI instead of direct DB manipulation
- **By how much**: Webhook creation time under 60 seconds (vs minutes of manual DB work)
- **Measured by**: Time from "Create Webhook" click to having a working URL
- **Baseline**: No webhook management UI exists

### Technical Notes

- LiveView page, likely under a new route like `/chat/settings/webhooks`
- Or could be a modal/panel accessible from channel settings
- Token generation: `:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`, prefixed with `whk_`
- Token storage: hash with `:crypto.hash(:sha256, token)` before storing
- Depends on: US-01 (bot user identity), US-02 (webhook delivery endpoint)

---

## US-05: Webhook Delivery Hardening

### Problem

Dave Williams has a working webhook endpoint (US-02), but it lacks the safety measures needed for daily production use. Without rate limiting, a misconfigured CI job could flood a channel. Without proper error responses, debugging integration issues is frustrating. Dave needs confidence that the webhook endpoint is resilient and gives clear feedback when something goes wrong.

### Who

- Solo developer / admin | Operating webhooks in production | Needs resilient endpoint with clear error feedback

### Solution

Add rate limiting per webhook, structured error responses, and payload size enforcement to the webhook delivery endpoint.

### Domain Examples

#### 1: Happy Path -- Rate limit enforced

Dave's CI has a bug that triggers 100 webhook POSTs in 1 minute. After the first 60 succeed, subsequent requests receive `429 {"ok": false, "error": "rate_limited"}` with a `Retry-After: 30` header. The #deploys channel has 60 messages but isn't flooded further.

#### 2: Error Path -- Structured error for debugging

A new monitoring tool POSTs to the webhook with body `{"msg": "CPU high"}` (wrong field name). The response is `400 {"ok": false, "error": "missing_text_field"}`. The developer reads the error, changes `msg` to `text`, and the next POST succeeds.

#### 3: Error Path -- Oversized payload caught early

A log aggregator accidentally sends a 50KB payload. Slackex responds `413 {"ok": false, "error": "payload_too_large"}` without attempting to parse or store the body.

### UAT Scenarios (BDD)

#### Scenario: Rate limiting kicks in after threshold

Given a webhook "Deploy Bot" exists for "#deploys"
And the rate limit is 60 requests per minute per webhook
When 61 POSTs are sent to the webhook within 1 minute
Then the first 60 return 200
And the 61st returns 429 with "rate_limited" error
And the response includes a Retry-After header

#### Scenario: Rate limit resets after window

Given a webhook was rate-limited 2 minutes ago
When a new POST is sent to the webhook
Then the response is 200 and the message is delivered

#### Scenario: Structured error for invalid JSON

Given a webhook exists with a valid token
When a POST is sent with body "not valid json"
Then the response is 400 with `{"ok": false, "error": "invalid_json"}`

### Acceptance Criteria

- [ ] Rate limiting: 60 requests per minute per webhook (configurable)
  - Rolling 60-second window per webhook (not per-IP in MVP)
  - Rate limit is per webhook token, not per source IP
- [ ] 429 response includes Retry-After header
  - `Retry-After` header contains seconds until next available request
- [ ] All error responses use consistent JSON structure: `{"ok": false, "error": "error_code"}`
- [ ] Error codes are: invalid_token, missing_text_field, invalid_json, payload_too_large, rate_limited, channel_not_found
- [ ] Payload size limit enforced at 16KB

### Outcome KPIs

- **Who**: Dave (admin)
- **Does what**: Operates webhook endpoint without fear of abuse or silent failures
- **By how much**: Zero unhandled error cases; all failures return actionable error codes
- **Measured by**: Error response coverage (all documented codes return correctly)
- **Baseline**: Basic endpoint with no rate limiting or structured errors

### Technical Notes

- Rate limiting: reuse existing `SlackexWeb.Plugs.RateLimit` pattern (Redis-backed) with per-webhook key
- Payload size: `Plug.Parsers` `:length` option or a dedicated plug before JSON parsing
- Depends on: US-02 (webhook delivery endpoint)

---

## US-06: Webhook Management

### Problem

Dave Williams has working webhooks, but over time he needs to maintain them. If a webhook token is compromised, he needs to regenerate it without deleting and recreating the webhook. If he's troubleshooting, he wants to see when a webhook was last used. These are quality-of-life improvements for ongoing webhook operations.

### Who

- Solo developer / admin | Managing webhooks over time | Needs lifecycle management without DB access

### Solution

Add token regeneration, last-used timestamp tracking, and graceful handling of deleted channels to the webhook management UI.

### Domain Examples

#### 1: Happy Path -- Regenerate compromised token

Dave accidentally commits a webhook URL to a public repo. He opens webhook settings, clicks "Regenerate Token" on the "Deploy Bot" webhook, confirms the action. The old token is immediately invalidated. A new URL is displayed (shown once). Dave updates the GitHub Actions secret.

#### 2: Happy Path -- Check last-used timestamp

Dave hasn't seen deploy notifications in a while. He opens webhook settings and sees "Deploy Bot" last used 3 days ago. He realizes the CI pipeline has been broken, not the webhook.

#### 3: Edge Case -- Channel deleted after webhook created

Dave deletes the #monitoring channel. The "Alert Bot" webhook still exists but its target channel is gone. When a POST arrives, Slackex responds `404 {"ok": false, "error": "channel_not_found"}`. The webhook list shows "Alert Bot" with a warning that the target channel no longer exists.

### UAT Scenarios (BDD)

#### Scenario: Regenerate token

Given Dave has a webhook "Deploy Bot" for "#deploys" with token "whk_old_token"
When Dave clicks "Regenerate Token" and confirms
Then a new token is generated and displayed once
And the old token "whk_old_token" no longer works (returns 401)
And the new token successfully delivers messages

#### Scenario: Last-used timestamp updated on delivery

Given Dave has a webhook "Deploy Bot" with no previous deliveries
When a message is delivered via the webhook
Then the webhook's last_used_at timestamp is updated
And the webhook list shows "Last used: just now"

#### Scenario: Deleted channel handled gracefully

Given a webhook exists for channel "#monitoring"
And the "#monitoring" channel has been deleted
When a POST is sent to the webhook
Then the response is 404 with `{"ok": false, "error": "channel_not_found"}`
And the webhook list shows a warning about the missing channel

### Acceptance Criteria

- [ ] Regenerate token: old token invalidated immediately, new token shown once
- [ ] Last-used timestamp visible in webhook list
- [ ] Deleted target channel: webhook POST returns 404 with channel_not_found error
- [ ] Webhook list shows warning for webhooks with deleted target channels

### Outcome KPIs

- **Who**: Dave (admin)
- **Does what**: Manages webhook lifecycle through the UI
- **By how much**: Token regeneration in under 30 seconds, troubleshooting via last-used timestamp
- **Measured by**: Successful token rotation without webhook downtime beyond the rotation itself
- **Baseline**: No management capabilities -- must delete and recreate, or query DB directly

### Technical Notes

- Token regeneration: generate new token, hash and store, respond with plaintext (shown once)
- Last-used tracking: update `last_used_at` on webhook record during delivery (can be async/eventual)
- Channel deletion handling: check channel exists during webhook POST, return 404 if not
- Depends on: US-04 (webhook creation UI)
