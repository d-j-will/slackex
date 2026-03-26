import Ecto.Query

token =
  Slackex.Repo.one(
    from t in Slackex.Integrations.McpToken,
      where: t.name == "Claude",
      preload: [:bot_user]
  )

if is_nil(token) do
  IO.puts("ERROR: No MCP token named 'Claude' found")
else
  channels = Slackex.Chat.list_public_channels([])

  Enum.each(channels, fn ch ->
    Slackex.Chat.join_channel(token.bot_user.id, ch.id)
  end)

  IO.puts("Joined #{length(channels)} channels as #{token.bot_user.username}")
end
