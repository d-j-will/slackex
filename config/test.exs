import Config

config :slackex, env: :test

# Use BinaryBackend in tests — no EXLA compilation needed, keeps CI fast
config :nx, default_backend: Nx.BinaryBackend

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :slackex, Slackex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "slackex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :slackex, Slackex.ReadRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "slackex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :slackex, SlackexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4LAjB//8u+PVr8HijgYMicXqCWjPEa3eGszZfBvpHUwuxThF4Ctyy20QbEEVmxAM",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Faster password hashing in tests
config :bcrypt_elixir, log_rounds: 4

config :slackex, Oban, testing: :inline

config :libcluster, topologies: []

config :slackex, :redis_url, "redis://localhost:6379"

config :slackex, Slackex.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("AlhhcUBFZI1809fnVZuYlpT8GxESMBZ7XgtmRo16PA8=")}
  ]

config :slackex, Slackex.Encrypted.HMAC,
  algorithm: :sha256,
  secret: "test-only-hmac-secret"

config :fun_with_flags, :cache, enabled: false
config :fun_with_flags, :cache_bust_notifications, enabled: false

config :slackex, :flags_admin_auth,
  username: "admin",
  password: "testpassword"

# Disable OpenTelemetry tracing in tests to avoid noise
config :opentelemetry,
  traces_exporter: :none

# Use deterministic stub for embeddings in tests
config :slackex, :embedding_client, Slackex.Embeddings.StubClient

# Use deterministic stub for LLM in tests
config :slackex, :llm_client, Slackex.AI.StubLLMClient
