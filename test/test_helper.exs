ExUnit.start(exclude: [:e2e, :distributed, :bumblebee], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual)
