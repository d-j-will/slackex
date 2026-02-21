ExUnit.start(exclude: [:e2e, :distributed, :contract], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual)
