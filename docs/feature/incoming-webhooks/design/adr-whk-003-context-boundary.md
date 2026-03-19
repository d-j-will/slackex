# ADR-WHK-003: Webhook Context Boundary

## Status

Accepted

## Context

The incoming webhooks feature introduces new concepts: webhook records, token lifecycle, and the orchestration of bot user + channel setup. These need a home in the codebase. The project has existing contexts:

- `Slackex.Chat` (1557 lines via `chat.ex` facade) -- channels, messages, subscriptions, permissions
- `Slackex.Accounts` -- user schema, registration, authentication
- `Slackex.Messaging` -- real-time message routing via ChannelServer

The project's CLAUDE.md mandates: "Extract new features into separate modules -- Don't grow index.ex (1739 lines) or chat.ex (1557 lines) further."

## Decision

Create a new `Slackex.Integrations.Webhooks` context module under `lib/slackex/integrations/`.

The namespace `Integrations` is chosen over `Webhooks` at the top level because:
1. It provides a natural home for future integration types (outgoing webhooks, slash commands, OAuth apps)
2. It communicates intent: this is the boundary between Slackex and external systems
3. It avoids a flat namespace proliferation at the `Slackex.*` level

Structure:
- `lib/slackex/integrations/webhook.ex` -- Ecto schema
- `lib/slackex/integrations/webhooks.ex` -- context module (CRUD, token lifecycle, creation orchestration)

## Alternatives Considered

### Alternative A: Add to `Slackex.Chat` context

Webhook schema and functions added to the existing Chat context, since webhooks ultimately create messages in channels.

**Evaluation:**
- (+) No new context boundary to learn
- (+) Direct access to Channel/Subscription internals
- (-) Violates project convention against growing large files
- (-) Webhooks are about external system integration, not chat domain logic
- (-) Chat context already has 1557 lines; adding CRUD + token logic adds ~200 more

**Rejected because:** Violates the project's explicit file size convention. Webhooks are an integration concern, not a core chat concept. The Chat context should not know about token hashing or bot user lifecycle.

### Alternative B: Top-level `Slackex.Webhooks` context

Flat namespace at `Slackex.Webhooks` alongside `Slackex.Chat`, `Slackex.Accounts`, etc.

**Evaluation:**
- (+) Simple, direct naming
- (+) Easy to find
- (-) No namespace for future integration types (would need `Slackex.OutgoingWebhooks`, `Slackex.SlashCommands` etc.)
- (-) Proliferates top-level contexts

**Rejected because:** The `Integrations` namespace provides better organization for future extensibility without adding meaningful complexity today. A single developer can easily navigate `Integrations.Webhooks`.

## Consequences

### Positive

- **Clean boundary**: Webhook logic isolated from Chat and Accounts. Dependencies are explicit: `Integrations.Webhooks` depends on `Accounts` (bot user creation) and `Chat` (channel resolution, subscription).
- **Convention compliance**: No existing large files grow further.
- **Extensible namespace**: Future integration types (`Integrations.SlashCommands`, `Integrations.OAuthApps`) have a natural home.

### Negative

- **Cross-context orchestration**: Webhook creation requires coordinating across Accounts (bot user), Chat (channel + subscription), and Integrations (webhook record). This is handled via `Ecto.Multi` transaction in the Webhooks context.
- **New directory**: Adds `lib/slackex/integrations/` directory. Minimal cognitive overhead for a single developer.
