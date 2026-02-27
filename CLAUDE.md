# Slackex

## Project Overview

Elixir/Phoenix LiveView messaging application (Slack/Discord-style). PostgreSQL database with Docker for development. Snowflake IDs for message ordering. PubSub for real-time updates.

Key directories:
- `lib/slackex/` — domain contexts (Chat, Messaging, Accounts)
- `lib/slackex_web/` — LiveView, components, router
- `test/` — ExUnit tests (currently 666 tests)
- `priv/repo/migrations/` — Ecto migrations
- `docs/` — feature specs, evolution docs, research

## Development Paradigm

functional
@nw-functional-software-crafter

## CI / Pre-Commit

Always run `mix format` before committing Elixir code. CI enforces formatting and will fail on unformatted files.

Always run `mix test` before committing. Verify zero failures before staging changes. If CI includes `docker-compose` tests, ensure those configurations are updated too.

## Bug Fixing Guidelines

When fixing bugs in Phoenix LiveView:
- Verify all required assigns exist in the socket before referencing them in templates (e.g., `@voting_active`, `@current_scope`)
- Check existing codebase for actual module paths rather than guessing — use `Glob` or `Grep` to confirm
- Read the relevant LiveView module and template before proposing a fix

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
