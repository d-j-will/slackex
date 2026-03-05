# Slackex

## Project Overview

Elixir/Phoenix LiveView messaging application (Slack/Discord-style). PostgreSQL database with Docker for development. Snowflake IDs for message ordering. PubSub for real-time updates.

Key directories:
- `lib/slackex/` — domain contexts (Chat, Messaging, Accounts)
- `lib/slackex_web/` — LiveView, components, router
- `test/` — ExUnit tests (currently 1002 tests)
- `priv/repo/migrations/` — Ecto migrations
- `docs/` — feature specs, evolution docs, research

## Development Paradigm

functional
@nw-functional-software-crafter

## Production Resilience

Before adding any new supervised process, background worker, or external dependency:

1. **What happens when this fails?** Does the app keep serving traffic, or does it cascade?
2. **Is this essential or non-essential?** Essential (DB, PubSub, Endpoint) gets `restart: :permanent`. Non-essential (embeddings, analytics, sync) gets `restart: :temporary`.
3. **How are errors surfaced?** Silent failures (swallowed errors, `_ = result; :ok`) are worse than loud crashes. Every failure must be visible in logs and metrics.
4. **What is the blast radius?** A crash in one subsystem must not propagate to unrelated subsystems. Use dedicated supervisors with appropriate restart budgets.
5. **How does the system recover?** Degraded functionality should self-heal on next deploy or process restart, without manual intervention.

Incident precedent: v0.5.36 — EmbeddingWorker swallowed errors, cascaded through supervisor, took down the entire app. All CI gates had passed.

## Test Environment

Docker required: `docker compose up -d postgres_test redis` then `mix test`. Test DB on port 5433, Redis on 6379.

**Never dismiss test failures.** If tests fail due to infrastructure, fix the environment first.

### Ecto upsert safety

**Never use `on_conflict: :nothing` without handling the nil-id ghost struct.** When a conflict occurs, Ecto returns `{:ok, %Struct{id: nil}}` — a struct that looks successful but has no database identity.

```elixir
case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [...]) do
  {:ok, %MySchema{id: nil}} ->
    {:ok, Repo.get_by!(MySchema, unique_field: value)}
  other ->
    other
end
```

## UI Component Conventions

All modals and popovers must implement three dismiss mechanisms:
1. Backdrop click (`phx-click="close_..."` on the overlay div)
2. Escape key (`phx-window-keydown="close_..."` with `phx-key="Escape"`)
3. Explicit close button (X) using `<button phx-click="close_..." class="btn btn-ghost btn-sm btn-square"><span class="hero-x-mark size-5" /></button>`

## Skills and Hooks

The following are **enforced by hooks or guided by skills** — use them instead of manual steps:

- **Migrations**: Use `/new-migration`. Safety hook warns on NOT NULL without default, renames, drops, type changes.
- **Feature flags**: Use `/new-feature`. Guards both context module and LiveView template.
- **Deploy**: Use `/deploy`. Runs `scripts/pre-deploy` (7-step verification) then tags.
- **Oban workers**: Hook warns on `_ =` in `_worker.ex` files. Never discard `perform/1` return values.
- **CI deploy edits**: Hook warns on SSH heredoc issues in `ci-deploy.yml`.
- **Docker/Caddy**: Hooks block bare `docker pull`, `caddy reload`, `build:` in prod compose, `--no-verify`.

## Deployment Summary

- Deploys trigger on version tags (`refs/tags/v*`) only. Pushing to `master` runs CI checks only.
- **GPU is OFF-LIMITS** on the production server. Never enable EXLA/CUDA/OpenCL in prod config.
- Full deployment details: `docs/runbooks/deployment.md`
- Model deployment: `docs/runbooks/model-deployment.md`

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
