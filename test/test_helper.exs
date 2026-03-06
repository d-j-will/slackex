ExUnit.start(exclude: [:e2e, :distributed, :bumblebee], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual)

# Enable all feature flags in tests so new features are exercised by default.
# Individual tests can disable specific flags as needed.
Ecto.Adapters.SQL.Sandbox.checkout(Slackex.Repo)

for flag <- [
      :message_search,
      :channel_summarization,
      :reactions,
      :threads,
      :channel_management,
      :quick_switcher,
      :link_previews
    ] do
  FunWithFlags.enable(flag)
end

Ecto.Adapters.SQL.Sandbox.checkin(Slackex.Repo)
