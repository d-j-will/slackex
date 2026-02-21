# CI/CD & DevOps

## Goal

Establish a comprehensive CI/CD pipeline, local development environment, and pre-commit hooks that ensure code quality at every stage. Every commit is linted, type-checked, and tested before it can be merged.

## Local Development Setup

### Docker Compose (Development Dependencies)

```yaml
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: slackex_dev
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  postgres_test:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: slackex_test
    ports:
      - "5433:5432"
    tmpfs:
      - /var/lib/postgresql/data    # In-memory for fast tests
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
  redisdata:
```

### Setup Script (`bin/setup`)

One-command project bootstrap:
1. `docker compose up -d` — start Postgres + Redis
2. Wait for Postgres and Redis to be healthy
3. `mix deps.get` — install Elixir dependencies
4. `mix ecto.setup` — create DB, run migrations, seed
5. `mix assets.setup` + `mix assets.build` — install and build assets
6. Copy pre-commit and pre-push hooks to `.git/hooks/`
7. `mix dialyzer --plt` — build Dialyzer PLT (slow on first run)

### Dev Server Script (`bin/server`)

Ensures Docker services are running, then starts `iex -S mix phx.server`.

## Git Hooks

> **Sequencing:** Git hooks are set up in Phase 1 Step 1.3, before any domain code is written. See `01-phase-1-foundation.md`. All subsequent development is guarded by these hooks from the start.

### Pre-Commit Hook

**Blocking:** If any step fails, the commit is rejected. Runs checks in order (fails fast):
1. `mix format --check-formatted` — code formatting
2. `mix credo --strict --all` — linting
3. `mix compile --warnings-as-errors` — compilation + boundary checks
4. `mix dialyzer --format short` — type checking (only if `.ex`/`.exs` files changed)
5. `mix test` — test suite

### Pre-Push Hook

**Blocking:** If any step fails, the push is rejected. Runs the full CI-equivalent pipeline:
1. `mix compile --warnings-as-errors` — recompile to catch any issues missed by staged-only pre-commit
2. `mix dialyzer` — full type check (not conditional on changed files)
3. `mix test` — full test suite

### Hook Installation

Hooks are installed automatically by `bin/setup` (copies to `.git/hooks/`). If hooks are missing, run `bin/setup` again or manually copy from `priv/git_hooks/`. Hooks must not be bypassed with `--no-verify` — CI will catch violations, but the goal is to prevent bad commits from being created in the first place.

## Mix Aliases

```elixir
defp aliases do
  [
    setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
    "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
    "ecto.reset": ["ecto.drop", "ecto.setup"],
    "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
    "assets.build": ["tailwind slackex", "esbuild slackex"],
    "assets.deploy": ["tailwind slackex --minify", "esbuild slackex --minify", "phx.digest"],
    lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
    "lint.fix": ["format"],
    typecheck: ["dialyzer"],
    quality: ["lint", "typecheck", "test"],
    test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
    "test.watch": ["test.watch --stale"],
    ci: ["deps.get", "compile --warnings-as-errors", "format --check-formatted",
         "credo --strict", "dialyzer", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
  ]
end
```

## Static Analysis Configuration

### Credo (`.credo.exs`)

Strict mode enabled. Key settings:
- Included: `lib/`, `test/`; excluded: `_build/`, `deps/`, `priv/`
- Max line length: 120
- Max cyclomatic complexity: 12, max nesting: 3, max function arity: 6
- `TagTODO` exits with 0 (allowed), `TagFIXME` fails
- All standard consistency, readability, refactor, and warning checks enabled

### Formatter (`.formatter.exs`)

- Import deps: `:ecto`, `:ecto_sql`, `:phoenix`, `:oban`
- Plugins: `Phoenix.LiveView.HTMLFormatter`
- Inputs: `*.{heex,ex,exs}`, `{config,lib,test}/**/*.{heex,ex,exs}`, `priv/*/seeds.exs`

### Dialyzer

- PLT stored at `priv/plts/project.plt`
- Flags: `:unmatched_returns`, `:error_handling`, `:no_opaque`
- `.dialyzer_ignore.exs` for known false positives (initially empty)

## GitHub Actions CI Pipeline

### Quality Job (`quality`)

Runs on push/PR to main and develop.

**Services:** Postgres (pgvector:pg16) on port 5432, Redis (7-alpine) on port 6379.

**Caching:** deps, `_build`, and Dialyzer PLTs — keyed by OS + Elixir/OTP version + `mix.lock` hash.

**Steps:**
1. Checkout + setup Elixir (1.17.0 / OTP 27.0)
2. `mix deps.get`
3. `mix compile --warnings-as-errors`
4. `mix format --check-formatted`
5. `mix credo --strict`
6. `mix dialyzer --format github`
7. `mix ecto.create && mix ecto.migrate`
8. `mix test --cover --warnings-as-errors`
9. `mix test --include distributed --warnings-as-errors` — distributed cluster tests (Phase 3+). These verify Horde failover, split-brain fencing, and replica consistency. Separated from step 8 because they require `LocalCluster` and are slower, but they **must** run in CI as they cover critical distributed safety guarantees.
10. `mix hex.audit` — check for retired dependencies
11. `mix deps.unlock --check-unused` — check for unused dependencies

### Docker Job (`docker`)

Runs after `quality` passes. Builds Docker image using BuildKit with GitHub Actions cache (`type=gha`). Push disabled (build verification only).

## Production Dockerfile

Two-stage build:
- **Build stage** (`hexpm/elixir:1.17.0-erlang-27.0-debian-bookworm`): install build tools, hex/rebar, compile deps (cached layer), compile assets, compile app, create release
- **Runtime stage** (`debian:bookworm-slim`): minimal runtime deps (libstdc++6, openssl, libncurses5, curl), UTF-8 locale, non-root user (`slackex:slackex`), tini as init process for proper signal handling

Key runtime config: `RELEASE_DISTRIBUTION=name`, port 4000 exposed, healthcheck on `/health`.

## Release Configuration (`config/runtime.exs`)

Production config reads from environment variables:
- **Database:** `DATABASE_URL` (required), `POOL_SIZE` (default 20), `DATABASE_SSL`, `DATABASE_IPV6`
- **Read replica:** `DATABASE_READ_URL` (optional), `READ_POOL_SIZE` (default 10)
- **Web:** `SECRET_KEY_BASE` (required), `PHX_HOST` (required), `PORT` (default 4000)
- **Auth:** `GUARDIAN_SECRET_KEY` (required)
- **Cache:** `REDIS_URL` (default `redis://localhost:6379`)
- **AI:** `OPENAI_API_KEY` (optional — enables OpenAI embedding client)
- **Clustering:** `DNS_CLUSTER_QUERY` (Phase 1 dns_cluster fallback; Phase 3+ uses libcluster with K8s DNS or gossip strategy)
- **Oban:** configured with pruner, cron (CacheWarmer hourly, PartitionMaintenance monthly), queues (default:10, notifications:20, embeddings:5)

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | prod | - | PostgreSQL connection URL |
| `DATABASE_READ_URL` | no | - | Read replica PostgreSQL URL (see Phase 3 ReadRepo) |
| `READ_POOL_SIZE` | no | `10` | Read replica connection pool size |
| `REDIS_URL` | prod | `redis://localhost:6379` | Redis connection URL |
| `SECRET_KEY_BASE` | prod | - | Phoenix secret (min 64 bytes) |
| `GUARDIAN_SECRET_KEY` | prod | - | JWT signing key for Guardian (mobile API auth) |
| `PHX_HOST` | prod | - | Hostname for URL generation |
| `PORT` | no | `4000` | HTTP port |
| `POOL_SIZE` | no | `20` | DB connection pool size |
| `OPENAI_API_KEY` | no | - | OpenAI API key for embeddings |
| `K8S_SERVICE_NAME` | k8s | `slackex-headless` | Kubernetes headless service |
| `SNOWFLAKE_NODE_ID` | prod | - | Unique 10-bit node ID (0-1023) for Snowflake ID generation. Use K8s StatefulSet pod ordinal. |
| `RELEASE_NODE` | cluster | - | BEAM node name (e.g., `slackex@10.0.1.5`) |
| `DATABASE_SSL` | no | `false` | Enable SSL for DB connection |

## Tidewave Integration

- Dev-only dependency: `{:tidewave, "~> 0.5", only: :dev}`
- Plug added in endpoint.ex before code reloading (guarded by `Code.ensure_loaded?/1`)
- LiveView debug annotations enabled in dev config
- Provides MCP server for AI-assisted development: runtime code intelligence, LiveView inspection, DB introspection, log tailing, interactive evaluation

## Acceptance Criteria

- [ ] `docker compose up` starts Postgres (with pgvector), test Postgres, and Redis
- [ ] `bin/setup` bootstraps the entire project from zero (deps, DB, assets, hooks, PLT)
- [ ] `bin/server` starts dev server with all dependencies running
- [ ] Pre-commit hook blocks commits that fail: format check, Credo, compile --warnings-as-errors, Dialyzer, tests
- [ ] Pre-push hook blocks pushes that fail: compilation, full Dialyzer, full test suite
- [ ] `mix lint` checks formatting + Credo + compilation warnings
- [ ] `mix typecheck` runs Dialyzer
- [ ] `mix quality` runs full quality pipeline (lint + typecheck + test)
- [ ] `mix ci` runs the complete CI pipeline locally
- [ ] GitHub Actions CI passes on push/PR to main and develop
- [ ] CI caches deps, _build, and Dialyzer PLTs across runs
- [ ] CI runs hex.audit and deps.unlock --check-unused for security
- [ ] Docker build produces a working production image
- [ ] Production image runs as non-root user
- [ ] Liveness endpoint at `/health` returns 200 when BEAM node and database are responsive
- [ ] Readiness endpoint at `/ready` reports database, Redis (informational), and cluster status
- [ ] All environment variables are documented
- [ ] Tidewave MCP server is accessible in dev environment
- [ ] `.gitignore` excludes all generated/sensitive files
