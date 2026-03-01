import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/slackex start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :slackex, SlackexWeb.Endpoint, server: true
end

config :slackex, :redis_url, System.get_env("REDIS_URL") || "redis://localhost:6379"

if config_env() == :prod do
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate a 32-byte key with: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  cloak_key_tag = System.get_env("CLOAK_KEY_TAG") || "AES.GCM.V1"

  primary_cipher =
    {:default, {Cloak.Ciphers.AES.GCM, tag: cloak_key_tag, key: Base.decode64!(cloak_key)}}

  ciphers =
    case System.get_env("CLOAK_RETIRED_KEY") do
      nil ->
        [primary_cipher]

      retired_key ->
        retired_tag = System.get_env("CLOAK_RETIRED_KEY_TAG") || "AES.GCM.V1"

        [
          primary_cipher,
          {:retired, {Cloak.Ciphers.AES.GCM, tag: retired_tag, key: Base.decode64!(retired_key)}}
        ]
    end

  config :slackex, Slackex.Vault, ciphers: ciphers

  hmac_secret =
    System.get_env("CLOAK_HMAC_SECRET") ||
      raise """
      environment variable CLOAK_HMAC_SECRET is missing.
      """

  config :slackex, Slackex.Encrypted.HMAC,
    algorithm: :sha256,
    secret: hmac_secret

  guardian_secret =
    System.get_env("GUARDIAN_SECRET_KEY") ||
      raise """
      environment variable GUARDIAN_SECRET_KEY is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :slackex, Slackex.Accounts.Guardian,
    issuer: "slackex",
    secret_key: guardian_secret

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :slackex, Slackex.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  read_database_url = System.get_env("DATABASE_READ_URL") || database_url

  config :slackex, Slackex.ReadRepo,
    # ssl: true,
    url: read_database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :slackex, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  libcluster_topologies =
    if System.get_env("LIBCLUSTER_ENABLED") == "true" do
      [
        k8s: [
          strategy: Cluster.Strategy.Kubernetes.DNS,
          config: [
            service: System.get_env("LIBCLUSTER_K8S_SERVICE") || "slackex-nodes",
            application_name: System.get_env("LIBCLUSTER_APP_NAME") || "slackex",
            namespace: System.get_env("LIBCLUSTER_K8S_NAMESPACE") || "default"
          ]
        ]
      ]
    else
      []
    end

  config :libcluster, topologies: libcluster_topologies

  config :slackex, SlackexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :slackex, SlackexWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :slackex, SlackexWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :slackex, Slackex.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
