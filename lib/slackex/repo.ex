defmodule Slackex.Repo do
  use Ecto.Repo,
    otp_app: :slackex,
    adapter: Ecto.Adapters.Postgres
end
