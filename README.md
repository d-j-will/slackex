# Slackex

Slackex is a Phoenix and LiveView chat application with realtime messaging, channels, DMs, threads, reactions, push notifications, search, and agent-facing integrations.

## Start The App

- Run `mix setup` to install and set up dependencies
- Start the server with `mix phx.server` or `iex -S mix phx.server`
- Open `http://localhost:4000`

## Key Docs

### Architecture

- `docs/architecture/README.md` - architecture doc index
- `docs/architecture/realtime-chat.md` - core realtime messaging pipeline
- `docs/architecture/threads-and-reactions.md` - reply and reaction flows
- `docs/architecture/notifications.md` - presence, push, and catch-up flows

### Related Design And Operations

- `docs/feature/mcp-server/design/architecture.md` - agent-facing MCP integration
- `docs/feature/markdown-rendering/design/architecture.md` - message content storage and render path
- `docs/runbooks/observability.md` - metrics and tracing runbook
- `docs/design/information-architecture.md` - chat navigation and screen structure
- `docs/engineering-principles.md` - deploy safety and engineering rules

## Project Shape

- `lib/slackex/` - domain logic and infrastructure
- `lib/slackex_web/` - LiveView UI, router, controllers, channels, and web-facing integrations
- `test/` - automated test suite
- `docs/` - plans, architecture notes, research, runbooks, and retrospectives

## Learn More

- Phoenix: https://www.phoenixframework.org/
- Phoenix Guides: https://hexdocs.pm/phoenix/overview.html
