# Slackex

## Project Overview

Elixir/Phoenix LiveView messaging application (Slack/Discord-style). PostgreSQL database with Docker for development. Snowflake IDs for message ordering. PubSub for real-time updates.

Key directories:
- `lib/slackex/` — domain contexts (Chat, Messaging, Accounts)
- `lib/slackex_web/` — LiveView, components, router
- `test/` — ExUnit tests (currently 838 tests)
- `priv/repo/migrations/` — Ecto migrations
- `docs/` — feature specs, evolution docs, research

## Development Paradigm

functional
@nw-functional-software-crafter

## CI / Pre-Commit

Always run `mix format` before committing Elixir code. CI enforces formatting and will fail on unformatted files.

Always run `mix test` before committing. Verify zero failures before staging changes. If CI includes `docker-compose` tests, ensure those configurations are updated too.

## Test Environment

**Never dismiss test failures.** If tests fail due to infrastructure (database not running, Redis unavailable, etc.), fix the environment first, then re-run tests. Do not treat infrastructure failures as "not our problem."

Test infrastructure startup:
1. Start Docker if not running: `open -a Docker` (wait for daemon with `docker info`)
2. Start test services: `docker compose up -d postgres_test redis`
3. Wait for readiness: `docker compose exec postgres_test pg_isready -U postgres`
4. Then run: `mix test`

Test database is `postgres_test` on port 5433 (configured in `config/test.exs`). Redis on port 6379.

## UI Component Conventions

All modals and popovers must implement three dismiss mechanisms:
1. Backdrop click (`phx-click="close_..."` on the overlay div)
2. Escape key (`phx-window-keydown="close_..."` with `phx-key="Escape"`)
3. Explicit close button (X) using `<button phx-click="close_..." class="btn btn-ghost btn-sm btn-square"><span class="hero-x-mark size-5" /></button>`

This applies regardless of the modal's visual layout. Centered cards without header bars still need a close button (positioned absolute top-right).

## Bug Fixing Guidelines

When fixing bugs in Phoenix LiveView:
- Verify all required assigns exist in the socket before referencing them in templates (e.g., `@voting_active`, `@current_scope`)
- Check existing codebase for actual module paths rather than guessing — use `Glob` or `Grep` to confirm
- Read the relevant LiveView module and template before proposing a fix

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
