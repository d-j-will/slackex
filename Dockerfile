# =============================================================================
# Build stage
# =============================================================================
FROM hexpm/elixir:1.19.2-erlang-28.1.1-debian-bookworm-20260223-slim AS build

ENV MIX_ENV=prod
# Force EXLA to compile for CPU only — GPU is off-limits on the production
# mini-PC (flaky GPU causes hard power-off under any intensive workload).
# This MUST be set before mix deps.compile so the EXLA NIF is built without GPU support.
ENV EXLA_TARGET=host

# Install build dependencies (git for heroicons, build-essential for bcrypt NIF)
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first for layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy config (needed before compile)
COPY config config

# Copy static assets (favicon, images, robots.txt)
COPY priv priv

# Copy application source (Tailwind @source scans lib/slackex_web for class usage)
COPY lib lib

# Compile the application
RUN mix compile

# Install esbuild + tailwind binaries
RUN mix assets.setup

# Copy asset source files (JS, CSS, vendor)
COPY assets assets

# Build, minify, and digest assets (must come after lib/ is present)
RUN mix assets.deploy

# Copy release overlay files
COPY rel rel

# Build the release
RUN mix release

# =============================================================================
# Runtime stage
# =============================================================================
FROM debian:bookworm-slim AS runtime

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Install minimal runtime dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales ca-certificates curl && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --system appuser && useradd --system --gid appuser appuser

WORKDIR /app

# Copy the release from the build stage
COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/slackex ./

# Create models directory for Bumblebee cache (volume mount point)
RUN mkdir -p /app/models && chown appuser:appuser /app/models

USER appuser

ENV PHX_SERVER=true

CMD ["/app/bin/server"]
