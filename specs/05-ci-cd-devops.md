# CI/CD & DevOps

## Goal

Establish a comprehensive CI/CD pipeline, local development environment, and pre-commit hooks that ensure code quality at every stage. Every commit is linted, type-checked, and tested before it can be merged.

## Local Development Setup

### Docker Compose (Development Dependencies)

```yaml
# docker-compose.yml
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

### Database Configuration

```elixir
# config/dev.exs
config :slackex, Slackex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "slackex_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# config/test.exs
config :slackex, Slackex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "slackex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
```

### Setup Script

```bash
#!/bin/bash
# bin/setup — One-command project bootstrap
set -euo pipefail

echo "==> Starting dependencies..."
docker compose up -d

echo "==> Waiting for Postgres..."
until docker compose exec postgres pg_isready -U postgres > /dev/null 2>&1; do
  sleep 1
done

echo "==> Waiting for Redis..."
until docker compose exec redis redis-cli ping > /dev/null 2>&1; do
  sleep 1
done

echo "==> Installing Elixir dependencies..."
mix deps.get

echo "==> Setting up database..."
mix ecto.setup

echo "==> Installing assets..."
mix assets.setup

echo "==> Building assets..."
mix assets.build

echo "==> Installing pre-commit hooks..."
cp bin/hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo "==> Building Dialyzer PLT (this takes a while on first run)..."
mix dialyzer --plt

echo ""
echo "Setup complete! Run 'mix phx.server' to start."
echo "Tidewave MCP server will be available at the Phoenix endpoint."
```

### Dev Server Script

```bash
#!/bin/bash
# bin/server — Start dev server with all dependencies
set -euo pipefail

# Ensure Docker services are running
docker compose up -d

# Start Phoenix with iex
iex -S mix phx.server
```

## Pre-Commit Hook

```bash
#!/bin/bash
# bin/hooks/pre-commit — Runs before every git commit
set -euo pipefail

echo "==> Running pre-commit checks..."

# 1. Format check
echo "  Checking formatting..."
mix format --check-formatted
if [ $? -ne 0 ]; then
  echo "ERROR: Code is not formatted. Run 'mix format' and try again."
  exit 1
fi

# 2. Credo (linting)
echo "  Running Credo..."
mix credo --strict --all
if [ $? -ne 0 ]; then
  echo "ERROR: Credo found issues. Fix them and try again."
  exit 1
fi

# 3. Compile with warnings as errors (includes Boundary checks)
echo "  Compiling (warnings as errors)..."
mix compile --warnings-as-errors
if [ $? -ne 0 ]; then
  echo "ERROR: Compilation warnings found. Fix them and try again."
  exit 1
fi

# 4. Dialyzer (type checking) — only on changed files for speed
echo "  Running Dialyzer..."
CHANGED_FILES=$(git diff --cached --name-only --diff-filter=ACM -- '*.ex' '*.exs')
if [ -n "$CHANGED_FILES" ]; then
  mix dialyzer --format short
  if [ $? -ne 0 ]; then
    echo "ERROR: Dialyzer found type errors. Fix them and try again."
    exit 1
  fi
fi

# 5. Tests
echo "  Running tests..."
mix test
if [ $? -ne 0 ]; then
  echo "ERROR: Tests failed. Fix them and try again."
  exit 1
fi

echo "==> All pre-commit checks passed!"
```

## Mix Aliases

```elixir
# In mix.exs:
defp aliases do
  [
    # Setup
    setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
    "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
    "ecto.reset": ["ecto.drop", "ecto.setup"],

    # Assets
    "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
    "assets.build": ["tailwind slackex", "esbuild slackex"],
    "assets.deploy": ["tailwind slackex --minify", "esbuild slackex --minify", "phx.digest"],

    # Quality
    lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"],
    "lint.fix": ["format"],
    typecheck: ["dialyzer"],
    quality: ["lint", "typecheck", "test"],

    # Test
    test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
    "test.watch": ["test.watch --stale"],

    # CI (full pipeline)
    ci: ["deps.get", "compile --warnings-as-errors", "format --check-formatted",
         "credo --strict", "dialyzer", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
  ]
end
```

## Credo Configuration

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/"]
      },
      plugins: [],
      requires: [],
      checks: %{
        enabled: [
          # Consistency
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # Design
          {Credo.Check.Design.AliasUsage, [priority: :low, if_nested_deeper_than: 2]},
          {Credo.Check.Design.TagTODO, [exit_status: 0]},
          {Credo.Check.Design.TagFIXME, []},

          # Readability
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, [priority: :low]},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},

          # Refactor
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapInto, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.UnlessWithElse, []},

          # Warning
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValue, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []}
        ]
      }
    }
  ]
}
```

## Formatter Configuration

```elixir
# .formatter.exs
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :oban],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
```

## Dialyzer Configuration

```elixir
# .dialyzer_ignore.exs
# List of known false positives
[
  # Phoenix generates some patterns Dialyzer doesn't understand
  # Add specific ignore patterns as they arise during development
]
```

## GitHub Actions CI Pipeline

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

env:
  MIX_ENV: test
  ELIXIR_VERSION: "1.17.0"
  OTP_VERSION: "27.0"

permissions:
  contents: read

jobs:
  quality:
    name: Quality Checks
    runs-on: ubuntu-latest

    services:
      postgres:
        image: pgvector/pgvector:pg16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: slackex_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      # --- Dependency Caching ---
      - name: Cache deps
        uses: actions/cache@v4
        id: deps-cache
        with:
          path: deps
          key: deps-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ hashFiles('**/mix.lock') }}
          restore-keys: |
            deps-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-

      - name: Cache _build
        uses: actions/cache@v4
        with:
          path: _build
          key: build-${{ runner.os }}-${{ env.MIX_ENV }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ hashFiles('**/mix.lock') }}
          restore-keys: |
            build-${{ runner.os }}-${{ env.MIX_ENV }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-

      - name: Cache Dialyzer PLTs
        uses: actions/cache@v4
        with:
          path: priv/plts
          key: plts-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ hashFiles('**/mix.lock') }}
          restore-keys: |
            plts-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-

      # --- Install & Compile ---
      - name: Install dependencies
        run: mix deps.get

      - name: Compile (warnings as errors)
        run: mix compile --warnings-as-errors

      # --- Quality Gates (parallel where possible) ---
      - name: Check formatting
        run: mix format --check-formatted

      - name: Credo (linting)
        run: mix credo --strict

      - name: Dialyzer (type checking)
        run: |
          mkdir -p priv/plts
          mix dialyzer --format github

      # --- Database & Tests ---
      - name: Setup database
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/slackex_test
        run: mix ecto.create && mix ecto.migrate

      - name: Run tests
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/slackex_test
          REDIS_URL: redis://localhost:6379
        run: mix test --cover --warnings-as-errors

      # --- Security ---
      - name: Check for retired dependencies
        run: mix hex.audit

      - name: Check for unused dependencies
        run: mix deps.unlock --check-unused

  # Build Docker image to verify it compiles
  docker:
    name: Docker Build
    runs-on: ubuntu-latest
    needs: quality

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: false
          tags: slackex:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

## Production Dockerfile

```dockerfile
# Dockerfile
# ---- Build Stage ----
FROM hexpm/elixir:1.17.0-erlang-27.0-debian-bookworm AS build

RUN apt-get update && \
    apt-get install -y build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Cache deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Cache assets
COPY assets assets
COPY priv priv

# Compile app
COPY lib lib
COPY config config

RUN mix assets.deploy
RUN mix compile
RUN mix release

# ---- Runtime Stage ----
FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales curl tini && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Non-root user
RUN groupadd -r slackex && useradd -r -g slackex slackex

WORKDIR /app
COPY --from=build --chown=slackex:slackex /app/_build/prod/rel/slackex ./

USER slackex

ENV RELEASE_DISTRIBUTION=name
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:4000/health || exit 1

# Use tini as init to handle signals properly
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bin/slackex", "start"]
```

## Release Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  config :slackex, Slackex.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    ssl: System.get_env("DATABASE_SSL") == "true",
    socket_options: if(System.get_env("DATABASE_IPV6") == "true", do: [:inet6], else: [])

  # Read replica (optional)
  if read_url = System.get_env("DATABASE_READ_URL") do
    config :slackex, Slackex.ReadRepo,
      url: read_url,
      pool_size: String.to_integer(System.get_env("READ_POOL_SIZE") || "10"),
      read_only: true
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is not set"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST environment variable is not set"

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :slackex, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :slackex, SlackexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  # Guardian (JWT for mobile API auth)
  guardian_secret =
    System.get_env("GUARDIAN_SECRET_KEY") ||
      raise "GUARDIAN_SECRET_KEY environment variable is not set"

  config :slackex, Slackex.Guardian,
    secret_key: guardian_secret

  # Redis
  config :slackex, :redis_url,
    System.get_env("REDIS_URL") || "redis://localhost:6379"

  # OpenAI (for embeddings)
  if api_key = System.get_env("OPENAI_API_KEY") do
    config :slackex, :openai_api_key, api_key
    config :slackex, :embedding_client, Slackex.Embeddings.OpenAIClient
  end

  # Oban
  config :slackex, Oban,
    repo: Slackex.Repo,
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Cron, crontab: [
        {"0 * * * *", Slackex.Workers.CacheWarmer},
        {"0 0 1 * *", Slackex.Workers.PartitionMaintenance}
      ]}
    ],
    queues: [
      default: 10,
      notifications: 20,
      embeddings: 5
    ]
end
```

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
| `RELEASE_NODE` | cluster | - | BEAM node name (e.g., `slackex@10.0.1.5`) |
| `DATABASE_SSL` | no | `false` | Enable SSL for DB connection |

## Tidewave Integration

Tidewave is configured in Phase 1 but lives here for completeness:

```elixir
# mix.exs — dev only dependency
{:tidewave, "~> 0.5", only: :dev}

# lib/slackex_web/endpoint.ex — before code_reloading block
if Code.ensure_loaded?(Tidewave) do
  plug Tidewave
end

# config/dev.exs — enable LiveView debug annotations
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
```

Tidewave provides an MCP server that AI coding assistants (Claude Code, etc.) can connect to for:
- Runtime code intelligence (module/function lookups)
- LiveView component inspection
- Database schema introspection
- Log tailing and error inspection
- Interactive Elixir evaluation

The MCP server is automatically available at the Phoenix endpoint in development.

## .gitignore

```gitignore
# .gitignore
/_build/
/cover/
/deps/
/doc/
/.fetch
erl_crash.dump
*.ez
*.beam
/config/*.secret.exs
.elixir_ls/

# Assets
/assets/node_modules/
/priv/static/assets/

# Dialyzer
/priv/plts/*.plt
/priv/plts/*.plt.hash

# Docker
.docker/

# Environment
.env
.env.local
.env.production

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db
```

## Acceptance Criteria

- [ ] `docker compose up` starts Postgres (with pgvector), test Postgres, and Redis
- [ ] `bin/setup` bootstraps the entire project from zero (deps, DB, assets, hooks, PLT)
- [ ] `bin/server` starts dev server with all dependencies running
- [ ] Pre-commit hook runs: format check, Credo, compile --warnings-as-errors, Dialyzer, tests
- [ ] `mix lint` checks formatting + Credo + compilation warnings
- [ ] `mix typecheck` runs Dialyzer
- [ ] `mix quality` runs full quality pipeline (lint + typecheck + test)
- [ ] `mix ci` runs the complete CI pipeline locally
- [ ] GitHub Actions CI passes on push/PR to main and develop
- [ ] CI caches deps, _build, and Dialyzer PLTs across runs
- [ ] CI runs hex.audit and deps.unlock --check-unused for security
- [ ] Docker build produces a working production image
- [ ] Production image runs as non-root user
- [ ] Health endpoint at `/health` reports system status
- [ ] All environment variables are documented
- [ ] Tidewave MCP server is accessible in dev environment
- [ ] `.gitignore` excludes all generated/sensitive files
