# Slackex

## Project Overview

Elixir/Phoenix LiveView messaging application (Slack/Discord-style). PostgreSQL database with Docker for development. Snowflake IDs for message ordering. PubSub for real-time updates.

Key directories:
- `lib/slackex/` — domain contexts (Chat, Messaging, Accounts)
- `lib/slackex_web/` — LiveView, components, router
- `test/` — ExUnit tests (currently 849 tests)
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

FunWithFlags is installed and configured. Persistence is Ecto (via `Slackex.Repo`), cache is ETS with 15-min TTL, and cross-node cache busting uses `Slackex.PubSub`. The Actor protocol is implemented for `Slackex.Accounts.User` (returns `"user:<id>"`).

### Infrastructure
- **Admin UI**: `/admin/flags` — basic auth (dev: `admin`/`devpassword`, prod: `FLAGS_ADMIN_USER`/`FLAGS_ADMIN_PASSWORD` env vars)
- **Config**: `config/config.exs` (persistence, cache, notifications), `config/test.exs` (cache + notifications disabled)
- **Supervision**: FunWithFlags auto-starts as an OTP application — do NOT add `FunWithFlags.Supervisor` to `application.ex`
- **Table**: `fun_with_flags_toggles` (flag_name, gate_type, target, enabled)

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

Production runs two app containers behind a Caddy reverse proxy on a Docker host. The CI/CD pipeline (`.github/workflows/ci-deploy.yml`) builds a Docker image, pushes to GHCR, SSHes into the server to pull and restart containers using `docker-compose.prod.yml`, then restarts Caddy to pick up new upstream IPs.

### Docker Compose rules
- **Always use `docker compose pull`**, never bare `docker pull`. Docker Compose tracks image digests independently — a bare `docker pull` updates the local Docker cache but Compose may not recognise the change, silently running stale containers.
- **Always pass `--force-recreate --no-build --remove-orphans`** to `docker compose up`. `--force-recreate` ensures containers are replaced when the `:latest` digest changes. `--no-build` prevents rebuilding from stale local source. `--remove-orphans` cleans up containers from renamed/removed services that would otherwise keep running and intercept traffic.
- **Never define `build:` in `docker-compose.prod.yml`**. Production always uses pre-built images from GHCR.
- **Keep the server's compose file in sync** with the repo. The deploy step must `scp docker-compose.prod.yml` to the server before running `docker compose` commands — the server has no `git pull`.
- **Authenticate GHCR on the server** before pulling from private repos. Use `echo "$GITHUB_TOKEN" | ssh host docker login ghcr.io -u actor --password-stdin` before the SSH heredoc.

### Caddy reverse proxy rules
- **Use `docker restart caddy`, not `caddy reload`**, after recreating app containers. Caddy's `reload` compares the Caddyfile to its running config — if the file hasn't changed, it reports "config is unchanged" and retains stale cached DNS for upstreams that were recreated with new IPs. A full `docker restart` forces a cold start with fresh DNS resolution.
- **The Caddyfile is bind-mounted** from `/opt/caddy/Caddyfile` on the host into the Caddy container at `/etc/caddy/Caddyfile`. Edit the host file; it's the same file inside the container.
- **Never dump Caddyfile contents to CI logs** — it contains API tokens (e.g., Cloudflare DNS challenge credentials). Use targeted checks (e.g., `grep reverse_proxy /opt/caddy/Caddyfile`) when debugging.

### SSH heredoc rules
- **Redirect stdin from `/dev/null`** on any `docker compose exec`, `docker compose run`, or interactive command inside an SSH heredoc (`ssh host << 'EOF'`). These commands read from stdin by default, which **consumes the rest of the heredoc** — silently eating all subsequent commands. The shell exits 0, CI reports success, but nothing runs. Always use `docker compose exec ... < /dev/null`.
- **Redirect stderr to stdout (`2>&1`)** on all `docker compose` commands. Docker Compose writes progress and errors to stderr, which SSH heredocs don't forward to CI logs by default.
- **Add echo markers** before and after every deploy step. These appear in CI logs and make it trivial to spot where a deploy stalled or failed.
- **Make pre-deploy operations non-fatal** (e.g., database backups). Use `cmd && echo "done" || echo "failed (non-fatal)"` instead of relying on `set -e` for best-effort steps.

### Phoenix release config
- **Compile-time endpoint keys must be set in `config/prod.exs`**, not only in `config/runtime.exs`. Phoenix validates that compile-time config matches runtime values at boot — a mismatch crashes the release. Keys like `force_ssl`, `url`, `server`, and `cache_static_manifest` are compile-time. Set the value in `prod.exs` and (if needed) repeat or override it in `runtime.exs`.
- **After adding any endpoint config in `runtime.exs`**, check whether Phoenix treats it as compile-time by searching for `@compile_env` in the Phoenix source or testing with `MIX_ENV=prod mix compile` followed by a release boot.

### Pre-deploy verification
- **Never tag a deploy without verifying the full production surface.** Passing `mix test` locally is necessary but not sufficient — it does not test clustering, Docker networking, release boot, or env var availability.
- **Before tagging, check every file in `rel/`** (`env.sh.eex`, overlays) — these control Erlang distribution, node naming, and cookie derivation. A misconfigured `RELEASE_DISTRIBUTION` or `RELEASE_NODE` will crash the cluster silently.
- **If the change touches clustering, distribution, or node naming**, SSH into the server after deploy and verify with `docker compose -f docker-compose.prod.yml exec -T app1 curl -sf http://localhost:4000/health`. The `/health` endpoint returns JSON with `node`, `cluster_nodes`, and `cluster_size`. Cluster size must be 2.
- **The CI deploy workflow includes a smoke test** that hits `/health` on both app1 and app2 after container recreation. If either fails, the deploy step exits non-zero. A cluster size check warns if nodes haven't joined.

### General
- **Deploys only trigger on version tags** (`refs/tags/v*`). Pushing to `master` runs CI quality checks only. Remember to tag after merging if you want a deploy.
- **Always check the latest tag before creating a new one** — run `git tag --sort=-creatordate | head -5` and increment from the highest existing version. Tags that are numerically lower than the latest will not trigger a deploy.

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
