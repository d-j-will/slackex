defmodule Slackex.ReadRepo do
  # Leaf utility: freely depended upon (in: false), depends on nothing in-app.
  use Boundary, deps: [Slackex.Infrastructure], check: [in: false]

  @moduledoc false

  use Ecto.Repo,
    otp_app: :slackex,
    adapter: Ecto.Adapters.Postgres,
    read_only: true

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :types, Slackex.PostgrexTypes)}
  end

  defdelegate repo_for_age(id_or_atom), to: Slackex.ReadRepo.LagMonitor
  defdelegate lag_exceeded?(), to: Slackex.ReadRepo.LagMonitor
  defdelegate no_replica?(), to: Slackex.ReadRepo.LagMonitor
  defdelegate read_repo(), to: Slackex.ReadRepo.LagMonitor
end
