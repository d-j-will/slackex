# Architecture Docs

This directory collects system-level architecture notes for Slackex.

## Reading Order

1. `docs/architecture/realtime-chat.md` - core realtime messaging path, PubSub fanout, and batched persistence
2. `docs/architecture/threads-and-reactions.md` - thread replies, reply counts, reaction toggles, and LiveView update flow
3. `docs/architecture/notifications.md` - online presence, push preferences, device subscriptions, catch-up, and notification dispatch

## Related Design Docs

- `docs/feature/mcp-server/design/architecture.md` - agent-facing messaging and SSE integration
- `docs/feature/markdown-rendering/design/architecture.md` - message content storage and render pipeline
- `docs/runbooks/observability.md` - metrics and tracing for operating the system
- `docs/design/information-architecture.md` - UI navigation and screen structure
- `docs/engineering-principles.md` - cross-cutting operational and delivery rules

## Scope Guide

- Use the docs in this directory when you want to understand runtime behavior and component boundaries.
- Use the `docs/feature/` architecture docs when you want the design history and decisions for a specific feature.
- Use `docs/runbooks/` when you need operational procedures.
