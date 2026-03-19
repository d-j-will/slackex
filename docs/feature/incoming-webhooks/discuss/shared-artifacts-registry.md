# Shared Artifacts Registry: Incoming Webhooks

## Artifacts

### webhook_token

- **Source of truth**: Generated server-side on webhook creation via `:crypto.strong_rand_bytes/1`, stored as hashed value in `webhooks` table
- **Consumers**:
  - Webhook confirmation page (displayed once, plaintext)
  - Webhook URL construction (`/api/webhooks/${token}`)
  - Webhook controller (hashed lookup on each POST)
- **Owner**: Webhooks context
- **Integration risk**: HIGH -- token mismatch between creation display and storage hash breaks all webhook delivery
- **Validation**: Token shown on confirmation page must produce the same hash as stored value. After page navigation, token is irrecoverable (only hash persists).

### webhook_url

- **Source of truth**: Constructed from `${app_base_url}/api/webhooks/${webhook_token}`
- **Consumers**:
  - Webhook confirmation page (copy button)
  - Curl example on confirmation page
  - GitHub Actions secret (`SLACKEX_WEBHOOK_URL`)
  - External service HTTP client
- **Owner**: Webhooks context (construction), Router (routing)
- **Integration risk**: HIGH -- URL path must match Phoenix router definition exactly
- **Validation**: URL path `/api/webhooks/:token` must be defined in router and match the controller that performs token lookup.

### channel_name / channel_id

- **Source of truth**: `channels` table, `name` and `id` fields
- **Consumers**:
  - Webhook creation form (user input or selection)
  - Webhook confirmation page (display)
  - Webhook list (display)
  - Webhook record (`channel_id` foreign key)
  - Message delivery (target channel)
  - PubSub topic (`channel:${channel_id}`)
- **Owner**: Chat.Channels context
- **Integration risk**: MEDIUM -- channel deletion after webhook creation leaves orphaned webhook
- **Validation**: Webhook's `channel_id` must reference an existing channel. Webhook delivery must handle deleted channel gracefully (404 response, not crash).

### bot_user / bot_user_id

- **Source of truth**: `users` table, record with `is_bot: true`
- **Consumers**:
  - Webhook record (`bot_user_id` foreign key)
  - Message creation (`sender_id`)
  - Message display (username, display_name, avatar_url, BOT badge)
  - Channel subscription (bot user is member of target channel)
- **Owner**: Accounts context (user record), Webhooks context (association)
- **Integration risk**: HIGH -- bot user must exist and be subscribed to channel, otherwise message creation fails with permission error
- **Validation**: Bot user has `is_bot: true`. Bot user has subscription to webhook's target channel with role allowing `send_message`. Message display reads `is_bot` flag to show BOT badge.

### bot_display_name

- **Source of truth**: User input on webhook creation form, stored as `display_name` on bot User record
- **Consumers**:
  - Webhook creation form (input field)
  - Webhook confirmation page
  - Webhook list
  - Message display (sender name)
  - Optional: overridden per-message via `payload.username`
- **Owner**: Accounts context (User.display_name)
- **Integration risk**: LOW -- display-only, no functional impact on delivery
- **Validation**: Default to "Webhook" when not provided. Username override in POST payload is ephemeral (display only, does not modify the User record).

### payload_text

- **Source of truth**: JSON `"text"` field in webhook POST body
- **Consumers**:
  - Webhook controller (validation: required, non-empty)
  - Message creation (`content` field, encrypted via Cloak)
  - Message creation (`search_content` field, plaintext for FTS)
  - Message display (rendered via `Slackex.Markdown.to_html/1`)
- **Owner**: External service (producer), Webhooks context (consumer/validator)
- **Integration risk**: HIGH -- text flows through encryption, search indexing, and markdown rendering. Any pipeline break loses message content.
- **Validation**: Text must pass through the same `Message.changeset/2` as regular messages. Encrypted content must be decryptable. Search content must be indexable. Markdown rendering must sanitize HTML (existing Scrubber).

### payload_username

- **Source of truth**: JSON `"username"` field in webhook POST body (optional)
- **Consumers**:
  - Message display (overrides bot_display_name for that single message)
- **Owner**: External service (producer)
- **Integration risk**: LOW -- optional override, display-only
- **Validation**: If present, used as display name for the message. Does not modify the bot User record. If absent, falls back to bot user's display_name.

## Integration Checkpoints

### Checkpoint 1: Webhook Creation -> Channel + Bot User

- Channel exists or is auto-created
- Bot user created with `is_bot: true`
- Bot user subscribed to channel (role allows sending messages)
- Webhook record links channel_id and bot_user_id
- Token hashed before storage

### Checkpoint 2: Webhook POST -> Message Creation

- Token in URL resolves to active webhook record (hashed comparison)
- Webhook record provides channel_id and bot_user_id
- Message created through standard pipeline (Snowflake ID, Cloak encryption, search_content)
- Bot user has permission to send to channel (subscription exists)

### Checkpoint 3: Message Creation -> Real-Time Display

- PubSub envelope broadcast on `channel:${channel_id}` topic
- Envelope event is `"message.new"` (same as regular messages)
- LiveView `handle_info` processes envelope identically
- Message component checks `sender.is_bot` for BOT badge rendering
- Markdown rendering uses existing `Slackex.Markdown.to_html/1` pipeline
