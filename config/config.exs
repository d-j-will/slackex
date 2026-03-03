# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :slackex,
  ecto_repos: [Slackex.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# Guardian JWT configuration
config :slackex, Slackex.Accounts.Guardian,
  issuer: "slackex",
  secret_key: "dev-only-secret-key-override-in-prod"

# Configures the endpoint
config :slackex, SlackexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SlackexWeb.ErrorHTML, json: SlackexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Slackex.PubSub,
  live_view: [signing_salt: "3NtRMPiU"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  slackex: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  slackex: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :slackex, Oban,
  repo: Slackex.Repo,
  queues: [default: 10, notifications: 20, embeddings: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Slackex.Workers.CacheWarmer},
       {"*/15 * * * *", Slackex.Embeddings.ReconciliationWorker}
     ]}
  ]

config :slackex, Slackex.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("AlhhcUBFZI1809fnVZuYlpT8GxESMBZ7XgtmRo16PA8=")}
  ]

config :slackex, Slackex.Encrypted.HMAC,
  algorithm: :sha256,
  secret: "dev-only-hmac-secret-override-in-prod"

config :bcrypt_elixir, log_rounds: 12

config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: Slackex.Repo

config :fun_with_flags, :cache_bust_notifications,
  adapter: FunWithFlags.Notifications.PhoenixPubSub,
  client: Slackex.PubSub

config :fun_with_flags, :cache,
  enabled: true,
  ttl: 900

config :libcluster, topologies: []

config :slackex, :redis_url, "redis://localhost:6379"

# Embedding client — overridden to StubClient in dev/test
config :slackex, :embedding_client, Slackex.Embeddings.OpenAIClient

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
