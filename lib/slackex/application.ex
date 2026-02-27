defmodule Slackex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
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
      {Task.Supervisor, name: Slackex.WriteSupervisor},
      {Oban, Application.fetch_env!(:slackex, Oban)},
      # Start to serve requests, typically the last entry
      SlackexWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Slackex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SlackexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
