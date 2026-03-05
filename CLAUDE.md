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

**The application must keep serving traffic regardless of what fails.** This is the overriding design constraint. Continuous deployment requires that every layer — local checks, CI, and production runtime — independently prevents and tolerates failures. No single layer is sufficient; all must hold.

### Defense in depth

| Layer | Purpose | Catches |
|-------|---------|---------|
| **Pre-commit** (local) | Fast feedback before code leaves the machine | Format, lint, test, type errors |
| **CI pipeline** | Environment-specific validation | Docker build, release boot, integration tests, dialyzer |
| **Production runtime** | Tolerate what slipped through | Supervision isolation, error propagation, health checks, graceful degradation |

Each layer must assume the others can fail. CI passing does not mean production is safe. Tests passing does not mean runtime behavior under load is correct.

### Design questions (mandatory before shipping new subsystems)

Before adding any new supervised process, background worker, or external dependency to the application:

1. **What happens when this fails?** Does the app keep serving traffic, or does it cascade?
2. **Is this essential or non-essential?** Essential (DB, PubSub, Endpoint) gets `restart: :permanent`. Non-essential (embeddings, analytics, sync) gets `restart: :temporary`.
3. **How are errors surfaced?** Silent failures (swallowed errors, `_ = result; :ok`) are worse than loud crashes. Every failure must be visible in logs and metrics.
4. **What is the blast radius?** A crash in one subsystem must not propagate to unrelated subsystems. Use dedicated supervisors with appropriate restart budgets.
5. **How does the system recover?** Degraded functionality should self-heal on next deploy or process restart, without manual intervention.

### Incident precedent

v0.5.36: EmbeddingWorker swallowed errors, Embeddings.Supervisor had no cascade protection. User activity triggered Oban jobs that crashed the ML serving, exhausted supervisor restarts, and took down the entire application. All CI gates had passed.

## Shift-Left Principle

**Nothing that can break production build, test, or deployment may reach the CI/CD pipeline.** Every failure class that CI checks for must have a local equivalent that catches it before `git push`. If CI rejects a commit that could have been caught locally, that is a tooling gap to be fixed immediately.

This means:
- **Every CI check has a local counterpart.** Formatting, tests, dialyzer, YAML syntax, compile warnings — all runnable locally.
- **Pre-commit hooks are mandatory.** Install with `ln -sf ../../scripts/pre-commit .git/hooks/pre-commit`. The hook runs automatically; skipping it (`--no-verify`) is not acceptable.
- **When CI catches something the hook missed**, add that check to the hook or local workflow before fixing the code. Fix the tooling gap first, then fix the bug.
- **When adding a new CI check**, add the local equivalent in the same PR/commit.

## CI / Pre-Commit

The pre-commit hook (`scripts/pre-commit`) validates YAML syntax on `.yml`/`.yaml` files and runs `mix format --check-formatted` + `mix test --max-failures 1` on Elixir files.

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

### ETS cache isolation

Shared ETS tables (`:slackex_message_cache`, `:dm_rate_limits`) persist across tests and cause flaky failures when stale entries leak between modules. `DataCase.setup_sandbox/1` clears `:slackex_message_cache` before and after every test automatically.

Rules:
- **Never write incomplete maps to ETS in tests.** Always include at minimum `%{id: N, content: "...", sender_id: N}`. Incomplete maps leak to `ChannelServer.init` → `BatchWriter.to_row/1` and crash.
- **Tests using `ExUnit.Case` directly** (not `DataCase`/`ConnCase`) must add `on_exit(fn -> :ets.delete_all_objects(:slackex_message_cache) end)` in their setup block.
- **Never stuff synthetic data into GenServer state** without cleaning it up. If a test replaces `pending_writes` with fake data, clear it before the test exits so `terminate/2` doesn't try to flush garbage through BatchWriter.
- **`async: false` does NOT isolate across modules** — it only serializes tests within the same module. Multiple `async: false` modules can interleave. Centralized cleanup in `DataCase` is the only reliable isolation mechanism.

### Ecto upsert safety

**Never use `on_conflict: :nothing` without handling the nil-id ghost struct.** When a conflict occurs, Ecto returns `{:ok, %Struct{id: nil}}` — a struct that looks successful but has no database identity. Downstream code using the nil id will hit FK constraint violations.

Safe pattern:
```elixir
case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [...]) do
  {:ok, %MySchema{id: nil}} ->
    # Conflict: re-fetch the existing record
    {:ok, Repo.get_by!(MySchema, unique_field: value)}
  other ->
    other
end
```

This applies to any `Repo.insert` with `on_conflict: :nothing`. The race window exists even with a prior `get_by` check — in READ COMMITTED isolation, concurrent transactions can both see nil and both attempt the insert.

## OTP Supervision Resilience

Implements the Production Resilience principle (above) for OTP/Elixir specifics. Hook-enforced via `hookify.oban-worker-error-swallow`.

### Oban worker error handling

**Never discard errors in Oban `perform/1`.** The return value of `perform/1` tells Oban whether to retry. Returning `:ok` on failure means silent data loss with no retries and no visibility.

Dangerous pattern (NEVER do this):
```elixir
def perform(%Oban.Job{args: args}) do
  _ = do_work(args)  # discards {:error, reason}
  :ok                # Oban thinks it succeeded
end
```

Correct pattern:
```elixir
def perform(%Oban.Job{args: args}) do
  do_work(args)  # returns :ok | {:error, reason} | {:snooze, seconds}
end
```

### Non-essential supervisor isolation

**Non-essential supervisors must use `restart: :temporary`** in the main supervision tree. This prevents cascading crashes — if the subsystem exhausts its restart budget, it stays dead and the app keeps running.

```elixir
# In application.ex children list:
Supervisor.child_spec(MyApp.OptionalSubsystem.Supervisor, restart: :temporary)
```

This applies to: embedding/ML serving, search indexing, analytics, background sync — anything where degraded functionality is acceptable. It does NOT apply to: database, PubSub, endpoint, cache — core infrastructure that the app cannot function without.

### Dependency availability checks

**Workers must verify their backing service is alive before attempting work.** If the service is down, return `{:snooze, seconds}` to reschedule without counting as a failed attempt.

```elixir
defp ensure_serving_available do
  case Process.whereis(MyApp.RequiredProcess) do
    nil -> {:snooze, 30}
    _pid -> :ok
  end
end

def perform(%Oban.Job{} = job) do
  with :ok <- ensure_serving_available() do
    do_work(job)
  end
end
```

This prevents workers from hammering a crashed process, accelerating the supervisor restart loop, and exhausting the restart budget faster.

### Supervisor restart budgets

**Non-essential subsystems should use generous restart budgets** (e.g., `max_restarts: 5, max_seconds: 300`). Tight budgets (3/60s) are easily exhausted by transient failures like ML model compilation spikes or network blips, turning a recoverable problem into permanent subsystem death.

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

All migrations must be **deploy-safe** — follow the expand/contract pattern. **Always invoke `/new-migration` when a migration is needed** — do not create migration files directly.

Key rules (hook-enforced for the most dangerous cases):
- **Expand phase**: add nullable columns or columns with defaults; add indexes concurrently; never rename or drop.
- **Contract phase**: remove columns/tables only after all referencing code is deployed and stable.
- **Never in one migration**: rename a column/table, change a column type, add `NOT NULL` without a default, drop a column still in use.
- **Reversibility**: always test `mix ecto.migrate` + `mix ecto.rollback` + `mix ecto.migrate`.
- **Backfills** belong in a separate Mix task, not in the schema migration (avoid table locks).

### Deployment order
1. Deploy expand-compatible code
2. Run expand migration
3. Deploy code using only new schema
4. Run contract migration (if any)

## Feature Flag Discipline

All new user-facing features must be deployed behind a FunWithFlags feature flag and remain hidden until PO-approved. **Always invoke `/new-feature` when starting a user-facing feature** — do not add flag guards manually.

Key rules:
- **Guard both UI and logic** — flag check in the LiveView template (hide UI) AND in the context module (reject the action). Never rely on UI hiding alone.
- **One flag per feature** — no nested flags or dependencies.
- **Name flags descriptively** — snake_case atoms: `:threaded_replies`, `:message_reactions`.
- **Clean up promptly** — remove flag and old code path after global enable (contract phase).

Lifecycle: develop (flag off) → deploy (invisible) → PO validates → global enable → remove flag.

Infrastructure: admin UI at `/admin/flags` (dev: `admin`/`devpassword`). FunWithFlags auto-starts — never add its supervisor to `application.ex`.

## Deployment Discipline

Production runs two app containers behind a Caddy reverse proxy on a Docker host. The CI/CD pipeline (`.github/workflows/ci-deploy.yml`) builds a Docker image, pushes to GHCR, SSHes into the server to pull and restart containers using `docker-compose.prod.yml`, then restarts Caddy to pick up new upstream IPs.

### Docker Compose rules
- **Always use `docker compose pull`**, never bare `docker pull` — hook-enforced. Compose tracks digests independently; bare pull silently leaves containers on the old image.
- **Always pass `--force-recreate --no-build --remove-orphans`** to `docker compose up`. `--force-recreate` ensures containers are replaced when the `:latest` digest changes. `--no-build` prevents rebuilding from stale local source. `--remove-orphans` cleans up containers from renamed/removed services that would otherwise keep running and intercept traffic.
- **Never define `build:` in `docker-compose.prod.yml`** — hook-enforced. Production always uses pre-built images from GHCR.
- **Keep the server's compose file in sync** with the repo. The deploy step must `scp docker-compose.prod.yml` to the server before running `docker compose` commands — the server has no `git pull`.
- **Authenticate GHCR on the server** before pulling from private repos. Use `echo "$GITHUB_TOKEN" | ssh host docker login ghcr.io -u actor --password-stdin` before the SSH heredoc.

### Caddy reverse proxy rules
- **Use `docker restart caddy`, not `caddy reload`** — hook-enforced. Full restart forces fresh DNS; `reload` retains stale upstream IPs when the Caddyfile is unchanged.
- **The Caddyfile is bind-mounted** from `/opt/caddy/Caddyfile` on the host into the Caddy container at `/etc/caddy/Caddyfile`. Edit the host file; it's the same file inside the container.
- **Never use `import` directives in the Caddyfile.** Only the single Caddyfile file is bind-mounted — files written alongside it on the host (e.g., `/opt/caddy/slackex-proxy`) are not visible inside the container. `import` references to host paths cause Caddy to crash-loop on startup. Keep the full config inline.
- **Never dump Caddyfile contents to CI logs** — it contains API tokens (e.g., Cloudflare DNS challenge credentials). Use targeted checks (e.g., `grep reverse_proxy /opt/caddy/Caddyfile`) when debugging.
- **Enable active health checks** on `reverse_proxy` for automatic failover. Use `health_uri /health`, `health_interval 5s`, `health_timeout 3s`, `fail_duration 15s` inside the `reverse_proxy` block. Without health checks, stopping one node returns 502 for requests routed to it. The reference config is in the repo's `Caddyfile`.
- **Health checks require `health_headers { X-Forwarded-Proto https }`** when the app uses `force_ssl`. Caddy's health checker makes a plain HTTP request without forwarded-proto headers; Phoenix sees it as insecure and returns 301, which Caddy treats as unhealthy, marking all upstreams down and returning 503 to every request.

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

### Pre-tag checklist (mandatory before every version tag)

Every deploy is triggered by a version tag. Before tagging, verify the full production surface locally. `mix test` passing is necessary but not sufficient.

1. **Tests pass**: `mix test` — zero failures, zero flaky warnings.
2. **Formatting**: `mix format --check-formatted` — CI will reject unformatted code.
3. **Credo**: `mix credo` — no new warnings.
4. **Dialyzer**: `mix dialyzer` — zero warnings (CI treats these as failures).
5. **Docker image builds**: `docker build -t slackex:local .` — verifies the Dockerfile, runtime deps (curl, openssl, etc.), and asset compilation all work.
6. **Docker image boots**: `docker run --rm -e SECRET_KEY_BASE=test -e DATABASE_URL=ecto://x:x@host/db slackex:local bin/slackex eval "IO.puts(:ok)"` — verifies the release boots without crashing on missing compile-time config.
7. **YAML valid**: `ruby -ryaml -e "YAML.safe_load(File.read('.github/workflows/ci-deploy.yml'))"` — caught by pre-commit hook, but verify if editing CI config outside the hook.

Run `scripts/pre-deploy` to execute steps 1-7 automatically. If any step fails, do not tag.

### General
- **Deploys only trigger on version tags** (`refs/tags/v*`). Pushing to `master` runs CI quality checks only. Remember to tag after merging if you want a deploy.
- **Always check the latest tag before creating a new one** — run `git tag --sort=-creatordate | head -5` and increment from the highest existing version. Tags that are numerically lower than the latest will not trigger a deploy.

## General Workflow

When the user provides a specific URL, package name, or configuration detail, use it immediately rather than exploring the codebase first. Ask for missing specifics upfront before starting work.
