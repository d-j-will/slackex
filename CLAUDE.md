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

Run `mix dialyzer` after making code changes to catch type errors locally before CI. Fix all warnings — CI treats dialyzer warnings as failures. Common fix: use `_ = expr` to explicitly discard return values from fire-and-forget calls (PubSub.broadcast, Process.send_after, etc.).

CI services must match local test infrastructure. The test database runs on port 5433 (not the default 5432) — both locally via `docker compose` and in CI via the GitHub Actions service port mapping. When modifying `config/test.exs` database settings or `.github/workflows/ci-deploy.yml` service ports, keep them in sync.

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

## Migration Discipline

All database migrations must be **deploy-safe** — the old application code must continue working while the new migration is applied. Follow the expand/contract pattern:

### Expand phase (deploy N)
- **Add columns as nullable** (or with defaults). Never add `NOT NULL` columns without a default in a single step.
- **Add new tables** freely — old code simply ignores them.
- **Add new indexes** concurrently: use `@disable_ddl_transaction true` and `@disable_migration_lock true` with `CREATE INDEX CONCURRENTLY`.
- **Keep old columns/tables in place** — do not rename or remove anything the running code still references.

### Contract phase (deploy N+1 or later)
- **Remove old columns/tables** only after all code referencing them has been deployed and is stable.
- **Add NOT NULL constraints** only after backfilling existing rows (use a data migration or separate step).
- **Drop indexes** that are no longer needed.

### Never in a single migration
- Rename a column or table (expand: add new, migrate data, contract: drop old)
- Change a column type (expand: add new column, backfill, contract: drop old)
- Add a NOT NULL column without a default
- Drop a column still referenced by running code

### Ecto-specific rules
- Use `Ecto.Migration.execute/2` for reversible raw SQL.
- Long-running data migrations belong in a separate task/script, not in a schema migration — avoid locking tables.
- Test migrations both directions: `mix ecto.migrate` then `mix ecto.rollback` to verify reversibility.
- Prefix migration filenames descriptively: `add_`, `create_`, `drop_`, `backfill_`, `remove_`.

### Deployment order
1. Deploy code that handles both old and new schema (expand-compatible)
2. Run the expand migration
3. Deploy code that uses only the new schema
4. Run the contract migration (if any)

## Feature Flag Discipline

All new user-facing features must be deployed behind a feature flag (FunWithFlags) and remain hidden until the Product Owner is satisfied. This applies to the expand/contract workflow:

### Lifecycle
1. **Develop** — implement the feature behind `FunWithFlags.enabled?(:feature_name, for: user)`. The flag defaults to off.
2. **Deploy** — code ships to production but is invisible to users.
3. **PO validation** — enable the flag for specific test users or groups via the admin UI. PO validates the feature in production.
4. **Release** — PO approves, flag is enabled globally.
5. **Contract** — remove the flag check and any old code path in a follow-up PR. Delete the flag from the admin UI.

### Rules
- **Never expose unfinished features** — if it's not behind a flag, it must be complete and approved.
- **One flag per feature** — don't nest flags or create complex flag dependencies.
- **Name flags descriptively** — use snake_case atoms: `:threaded_replies`, `:message_reactions`, not `:feature_1`.
- **Clean up promptly** — flags that have been globally enabled for more than one release cycle should be removed (contract phase).
- **Guard both UI and logic** — check the flag in the LiveView (to hide UI elements) and in the context module (to reject API calls). Don't rely on UI hiding alone.
- **Flag checks are cheap** — FunWithFlags uses ETS cache, so checking flags in hot paths is fine.

### In templates
```elixir
<%= if FunWithFlags.enabled?(:new_feature, for: @current_user) do %>
  <.new_feature_component />
<% end %>
```

### In context modules
```elixir
def some_action(user, params) do
  if FunWithFlags.enabled?(:new_feature, for: user) do
    # new behaviour
  else
    {:error, :not_available}
  end
end
```

## Deployment Discipline

Production runs on a Docker host via SSH. The CI/CD pipeline (`.github/workflows/ci-deploy.yml`) builds a Docker image, pushes to GHCR, then SSHes into the server to pull and restart containers using `docker-compose.prod.yml`.

### Deploy pipeline rules
- **Always use `docker compose pull`**, never bare `docker pull`. Docker Compose tracks image digests independently — a bare `docker pull` updates the local Docker cache but Compose may not recognise the change, silently running stale containers.
- **Always pass `--force-recreate --no-build`** to `docker compose up`. Without `--force-recreate`, Compose may skip recreating containers when the `:latest` tag points to a new digest. `--no-build` prevents Compose from building from a local Dockerfile that may contain old source.
- **Never define `build:` in `docker-compose.prod.yml`**. Production always uses pre-built images from GHCR. A `build` section risks Compose rebuilding from stale local source on the server.
- **Keep the server's compose file in sync** with the repo. The deploy step must `scp docker-compose.prod.yml` to the server before running `docker compose` commands. The server has no `git pull` — if the compose file diverges, deploys silently misbehave.
- **Redirect stderr to stdout (`2>&1`)** on all `docker compose` commands in the deploy script. Docker Compose writes progress and errors to stderr, which SSH heredocs don't forward to CI logs by default. Without this, deploy failures are invisible.
- **Add echo markers** before and after every deploy step (`echo "Pulling latest image..."`, `echo "Deploy complete."`). These appear in CI logs and make it trivial to spot where a deploy stalled or failed.
- **Make pre-deploy operations non-fatal** (e.g., database backups). Use `cmd && echo "done" || echo "failed (non-fatal)"` instead of relying on `set -e` for best-effort steps. A failing backup should not block the entire deploy.
- **Deploys only trigger on version tags** (`refs/tags/v*`). Pushing to `master` runs CI quality checks only. Remember to tag after merging if you want a deploy.

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
