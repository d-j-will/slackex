defmodule Slackex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _ = Slackex.AI.Telemetry.attach_handlers()

    children =
      [
        SlackexWeb.Telemetry,
        Slackex.Chat.DMRateLimiter,
        Slackex.Vault,
        Slackex.Repo,
        Slackex.ReadRepo,
        Slackex.ReadRepo.LagMonitor,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Slackex.ClusterSupervisor]]},
        Slackex.NodeListener,
        {Phoenix.PubSub, name: Slackex.PubSub},
        SlackexWeb.Presence,
        Slackex.Infrastructure.Snowflake,
        Slackex.Cache.Local,
        Slackex.Cache.Redis,
        Slackex.Messaging.ChannelRegistry,
        Slackex.Messaging.ChannelSupervisor,
        {Task.Supervisor, name: Slackex.WriteSupervisor}
      ] ++
        maybe_embedding_serving([]) ++
        [
          {Oban, Application.fetch_env!(:slackex, Oban)},
          Slackex.Embeddings.PersistenceListener,
          # FunWithFlags auto-starts via OTP app dependency ordering (before Slackex.Application).
          # Its Ecto adapter queries are lazy, so the Repo being started here first is safe.
          # Start to serve requests, typically the last entry
          SlackexWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Slackex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Conditionally includes the Embeddings.Supervisor in the children list when
  the configured embedding client is BumblebeeClient.

  The supervisor is started with `restart: :temporary` so that if it exhausts
  its own restart budget and dies, the main application supervisor does NOT
  attempt to restart it — the app keeps serving traffic with embeddings
  degraded rather than cascading a full shutdown.
  """
  @spec maybe_embedding_serving([Supervisor.child_spec()]) :: [Supervisor.child_spec()]
  def maybe_embedding_serving(children) do
    case Application.get_env(:slackex, :embedding_client) do
      Slackex.Embeddings.BumblebeeClient ->
        spec = Supervisor.child_spec(Slackex.Embeddings.Supervisor, restart: :temporary)
        children ++ [spec]

      _other ->
        children
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SlackexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
