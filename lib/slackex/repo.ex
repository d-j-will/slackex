defmodule Slackex.Repo do
  use Ecto.Repo,
    otp_app: :slackex,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :types, Slackex.PostgrexTypes)}
  end
end
