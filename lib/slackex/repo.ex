defmodule Slackex.Repo do
  # Leaf utility: freely depended upon (in: false), depends on nothing in-app.
  use Boundary, deps: [], check: [in: false]

  use Ecto.Repo,
    otp_app: :slackex,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :types, Slackex.PostgrexTypes)}
  end
end
