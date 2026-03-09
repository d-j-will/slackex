defmodule Slackex.Chat.ReadState do
  @moduledoc "Manages read cursors and unread counts for channels and DMs."

  import Ecto.Query

  alias Slackex.Chat.{DMConversation, Message, ReadCursor, Subscription}
  alias Slackex.Repo

  @no_cursor_message_id 0
  @valid_cursor_fields [:channel_id, :dm_conversation_id]

  @doc """
  Upserts the read cursor for a user/channel to the latest message ID.
  """
  def mark_as_read(user_id, channel_id) do
    upsert_read_cursor(user_id, :channel_id, channel_id)
  end

  @doc """
  Counts unread messages for a user in a channel (messages after their cursor).
  """
  def unread_count(user_id, channel_id) do
    cursor =
      Repo.one(
        from r in ReadCursor,
          where: r.user_id == ^user_id and r.channel_id == ^channel_id,
          select: r.last_read_message_id
      ) || @no_cursor_message_id

    Repo.one(
      from m in Message,
        where: m.channel_id == ^channel_id and m.id > ^cursor,
        select: count(m.id)
    ) || 0
  end

  @doc """
  Upserts the read cursor for a user/DM conversation to the latest message ID.
  """
  def mark_dm_as_read(user_id, dm_conversation_id) do
    upsert_read_cursor(user_id, :dm_conversation_id, dm_conversation_id)
  end

  @doc """
  Returns unread counts for all channels and DM conversations a user participates in.

  Uses exactly 2 queries: one for channels, one for DMs.

  Returns `%{channel_counts: %{channel_id => count}, dm_counts: %{dm_id => count}}`.
  Conversations with zero unread messages are included with count 0 (not absent).
  """
  def batch_unread_counts(user_id) do
    channel_counts = batch_channel_unread_counts(user_id)
    dm_counts = batch_dm_unread_counts(user_id)

    %{channel_counts: channel_counts, dm_counts: dm_counts}
  end

  defp upsert_read_cursor(user_id, target_field, target_id)
       when target_field in @valid_cursor_fields do
    latest_id = latest_message_id(target_field, target_id)

    attrs =
      %{user_id: user_id, last_read_message_id: latest_id}
      |> Map.put(target_field, target_id)

    %ReadCursor{}
    |> ReadCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_read_message_id, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(user_id, #{target_field}) WHERE #{target_field} IS NOT NULL"}
    )

    :ok
  end

  defp latest_message_id(target_field, target_id) do
    Repo.one(
      from m in Message,
        where: field(m, ^target_field) == ^target_id,
        select: max(m.id)
    ) || @no_cursor_message_id
  end

  defp batch_channel_unread_counts(user_id) do
    no_cursor = @no_cursor_message_id

    Repo.all(
      from s in Subscription,
        where: s.user_id == ^user_id,
        left_join: rc in ReadCursor,
        on: rc.user_id == ^user_id and rc.channel_id == s.channel_id,
        left_join: m in Message,
        on:
          m.channel_id == s.channel_id and
            m.id > coalesce(rc.last_read_message_id, ^no_cursor),
        group_by: s.channel_id,
        select: {s.channel_id, count(m.id)}
    )
    |> Map.new()
  end

  defp batch_dm_unread_counts(user_id) do
    no_cursor = @no_cursor_message_id

    Repo.all(
      from d in DMConversation,
        where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
        left_join: rc in ReadCursor,
        on: rc.user_id == ^user_id and rc.dm_conversation_id == d.id,
        left_join: m in Message,
        on:
          m.dm_conversation_id == d.id and
            m.id > coalesce(rc.last_read_message_id, ^no_cursor),
        group_by: d.id,
        select: {d.id, count(m.id)}
    )
    |> Map.new()
  end
end
