defmodule Slackex.Workers.CacheWarmer do
  @moduledoc "Oban worker that pre-warms message caches for recently active channels."

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Slackex.Chat
  alias Slackex.Messaging.ChannelSupervisor

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)
    channels = Chat.list_active_channels(since: since)

    Enum.each(channels, fn channel ->
      ChannelSupervisor.ensure_started({:channel, channel.id})
    end)

    :ok
  end
end
