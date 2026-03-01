# =============================================================================
# Build stage
# =============================================================================
FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20260223-slim AS build

ENV MIX_ENV=prod

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

# Copy assets for frontend build
COPY assets assets
COPY priv priv

# Download esbuild + tailwind binaries, then build & digest assets
RUN mix assets.setup
RUN mix assets.deploy

# Copy application source
COPY lib lib
COPY rel rel

# Compile the application
RUN mix compile

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
      libstdc++6 openssl libncurses5 locales ca-certificates && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --system appuser && useradd --system --gid appuser appuser

WORKDIR /app

# Copy the release from the build stage
COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/slackex ./

USER appuser

ENV PHX_SERVER=true

CMD ["/app/bin/server"]
