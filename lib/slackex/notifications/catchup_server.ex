defmodule Slackex.Notifications.CatchupServer do
  @moduledoc """
  Builds catch-up payloads for reconnecting users.

  When a user reconnects after being offline, this module computes the
  unread count and missed messages for each subscribed channel. Read
  cursors are checked in Redis first (fast path), falling back to DB.

  This is a pure function module — no GenServer needed. It composes
  existing Chat context queries and Cache.Redis cursor lookups.
  """

  import Ecto.Query

  alias Slackex.Cache.Redis, as: RedisCache
  alias Slackex.Chat
  alias Slackex.Chat.{Channel, Message, ReadCursor, Subscription}
  alias Slackex.Repo

  @max_missed_messages 100

  @type channel_catchup :: %{
          channel_id: integer(),
          channel_name: String.t(),
          channel_slug: String.t(),
          unread_count: non_neg_integer(),
          recent_messages: [map()]
        }

  @type catchup_result :: %{
          channels: [channel_catchup()],
          timestamp: DateTime.t()
        }

  @doc """
  Builds a catch-up payload for a reconnecting user.

  For each subscribed channel:
  1. Resolves the read cursor (Redis → DB → 0)
  2. Computes unread count (messages after cursor)
  3. Fetches missed messages (up to 100) from cursor position

  Returns `%{channels: [...], timestamp: DateTime.t()}`.
  """
  @spec build_catchup(integer()) :: catchup_result()
  def build_catchup(user_id) do
    channels = list_subscribed_channels(user_id)

    channel_catchups =
      Enum.map(channels, fn channel ->
        cursor = resolve_read_cursor(user_id, channel.id)
        unread = count_unread(channel.id, cursor)
        messages = fetch_missed_messages(channel.id, cursor)

        %{
          channel_id: channel.id,
          channel_name: channel.name,
          channel_slug: channel.slug,
          unread_count: unread,
          recent_messages: messages
        }
      end)

    %{
      channels: channel_catchups,
      timestamp: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp list_subscribed_channels(user_id) do
    Repo.all(
      from c in Channel,
        join: s in Subscription,
        on: s.channel_id == c.id and s.user_id == ^user_id,
        order_by: c.name,
        select: %{id: c.id, name: c.name, slug: c.slug}
    )
  end

  defp resolve_read_cursor(user_id, channel_id) do
    case RedisCache.get_read_cursor(user_id, {:channel, channel_id}) do
      {:ok, cursor_id} ->
        cursor_id

      :miss ->
        db_cursor(user_id, channel_id)
    end
  end

  defp db_cursor(user_id, channel_id) do
    Repo.one(
      from r in ReadCursor,
        where: r.user_id == ^user_id and r.channel_id == ^channel_id,
        select: r.last_read_message_id
    ) || 0
  end

  defp count_unread(channel_id, cursor) do
    Repo.one(
      from m in Message,
        where: m.channel_id == ^channel_id and m.id > ^cursor,
        select: count(m.id)
    ) || 0
  end

  defp fetch_missed_messages(channel_id, cursor) when cursor > 0 do
    messages =
      Chat.list_messages(channel_id, limit: @max_missed_messages, after: cursor)

    serialize_messages(messages)
  end

  defp fetch_missed_messages(channel_id, _cursor) do
    messages = Chat.list_messages(channel_id, limit: @max_missed_messages)
    serialize_messages(messages)
  end

  defp serialize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        id: to_string(msg.id),
        content: msg.content,
        sender_id: to_string(msg.sender_id),
        inserted_at: msg.inserted_at,
        sender: serialize_sender(msg.sender)
      }
    end)
  end

  defp serialize_sender(nil), do: nil
  defp serialize_sender(%Ecto.Association.NotLoaded{}), do: nil

  defp serialize_sender(user) do
    %{
      id: to_string(user.id),
      username: user.username,
      display_name: user.display_name
    }
  end
end
