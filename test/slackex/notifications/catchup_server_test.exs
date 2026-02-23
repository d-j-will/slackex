defmodule Slackex.Notifications.CatchupServerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Cache.Redis, as: RedisCache
  alias Slackex.Chat
  alias Slackex.Notifications.CatchupServer

  setup do
    # Clean Redis state between tests
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ets.delete_all_objects(:slackex_message_cache)

    user = insert(:user)
    %{user: user}
  end

  describe "build_catchup/1" do
    test "returns empty channels for user with no subscriptions", %{user: user} do
      result = CatchupServer.build_catchup(user.id)

      assert result.channels == []
      assert %DateTime{} = result.timestamp
    end

    test "returns subscribed channels with zero unread when no messages", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-empty-#{System.unique_integer()}"})

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.channel_id == channel.id
      assert catchup.channel_name == channel.name
      assert catchup.channel_slug == channel.slug
      assert catchup.unread_count == 0
      assert catchup.recent_messages == []
    end

    test "reports unread count for messages after read cursor", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-unread-#{System.unique_integer()}"})

      # Send 3 messages, mark first as read
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "First")
      {:ok, _msg2} = Chat.send_message(channel.id, user.id, "Second")
      {:ok, _msg3} = Chat.send_message(channel.id, user.id, "Third")

      # Set read cursor to first message
      Chat.mark_as_read(user.id, channel.id)
      # Now manually set cursor to msg1 (mark_as_read sets to latest)
      Slackex.Repo.query!(
        "UPDATE read_cursors SET last_read_message_id = $1 WHERE user_id = $2 AND channel_id = $3",
        [msg1.id, user.id, channel.id]
      )

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.unread_count == 2
    end

    test "returns missed messages after read cursor in chronological order", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-missed-#{System.unique_integer()}"})

      {:ok, msg1} = Chat.send_message(channel.id, user.id, "Read this")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Missed one")
      {:ok, msg3} = Chat.send_message(channel.id, user.id, "Missed two")

      # Set cursor to msg1
      Chat.mark_as_read(user.id, channel.id)

      Slackex.Repo.query!(
        "UPDATE read_cursors SET last_read_message_id = $1 WHERE user_id = $2 AND channel_id = $3",
        [msg1.id, user.id, channel.id]
      )

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert length(catchup.recent_messages) == 2

      [first, second] = catchup.recent_messages
      assert first.content == "Missed one"
      assert second.content == "Missed two"
      assert first.id == to_string(msg2.id)
      assert second.id == to_string(msg3.id)
    end

    test "serializes message fields correctly", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-serial-#{System.unique_integer()}"})

      {:ok, _msg} = Chat.send_message(channel.id, user.id, "Serialize me")

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert [message] = catchup.recent_messages

      # IDs serialized as strings (JS safety)
      assert is_binary(message.id)
      assert is_binary(message.sender_id)
      assert message.content == "Serialize me"
      assert %DateTime{} = message.inserted_at

      # Sender is serialized
      assert message.sender.username == user.username
      assert message.sender.display_name == user.display_name
      assert is_binary(message.sender.id)
    end

    test "handles multiple channels ordered by name", %{user: user} do
      {:ok, _ch_b} =
        Chat.create_channel(user.id, %{name: "beta-#{System.unique_integer()}"})

      {:ok, _ch_a} =
        Chat.create_channel(user.id, %{name: "alpha-#{System.unique_integer()}"})

      result = CatchupServer.build_catchup(user.id)

      assert length(result.channels) == 2
      [first, second] = result.channels
      assert first.channel_name < second.channel_name
    end

    test "uses Redis read cursor when available", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-redis-#{System.unique_integer()}"})

      {:ok, msg1} = Chat.send_message(channel.id, user.id, "Before cursor")
      {:ok, _msg2} = Chat.send_message(channel.id, user.id, "After cursor")

      # Set cursor in Redis only (no DB cursor)
      RedisCache.set_read_cursor(user_id(user), {:channel, channel.id}, msg1.id)

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.unread_count == 1
    end

    test "falls back to DB cursor when Redis misses", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-dbcur-#{System.unique_integer()}"})

      {:ok, msg1} = Chat.send_message(channel.id, user.id, "Read")
      {:ok, _msg2} = Chat.send_message(channel.id, user.id, "Unread")

      # Set cursor in DB only
      Chat.mark_as_read(user.id, channel.id)

      Slackex.Repo.query!(
        "UPDATE read_cursors SET last_read_message_id = $1 WHERE user_id = $2 AND channel_id = $3",
        [msg1.id, user.id, channel.id]
      )

      # Ensure Redis has no cursor (already flushed in setup)

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.unread_count == 1
    end

    test "limits missed messages to 100", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-limit-#{System.unique_integer()}"})

      # Send 105 messages
      {:ok, first_msg} = Chat.send_message(channel.id, user.id, "First")

      for i <- 2..105 do
        Chat.send_message(channel.id, user.id, "Msg #{i}")
      end

      # Set cursor to first message
      Chat.mark_as_read(user.id, channel.id)

      Slackex.Repo.query!(
        "UPDATE read_cursors SET last_read_message_id = $1 WHERE user_id = $2 AND channel_id = $3",
        [first_msg.id, user.id, channel.id]
      )

      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.unread_count == 104
      # Messages capped at 100
      assert length(catchup.recent_messages) == 100
    end

    test "does not include channels user is not subscribed to", %{user: user} do
      other_user = insert(:user)

      {:ok, _own_channel} =
        Chat.create_channel(user.id, %{name: "my-chan-#{System.unique_integer()}"})

      {:ok, _other_channel} =
        Chat.create_channel(other_user.id, %{name: "other-chan-#{System.unique_integer()}"})

      result = CatchupServer.build_catchup(user.id)

      assert length(result.channels) == 1
    end

    test "handles zero cursor (never read) by returning recent messages", %{user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "catchup-new-#{System.unique_integer()}"})

      {:ok, _msg1} = Chat.send_message(channel.id, user.id, "Hello")
      {:ok, _msg2} = Chat.send_message(channel.id, user.id, "World")

      # No cursor set at all — should return recent messages
      result = CatchupServer.build_catchup(user.id)

      assert [catchup] = result.channels
      assert catchup.unread_count == 2
      assert length(catchup.recent_messages) == 2
    end

    test "includes timestamp in result", %{user: user} do
      before = DateTime.utc_now()
      result = CatchupServer.build_catchup(user.id)
      after_call = DateTime.utc_now()

      assert DateTime.compare(result.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(result.timestamp, after_call) in [:lt, :eq]
    end
  end

  # Helper to get user id as expected by Redis cursor API
  defp user_id(%{id: id}), do: id
end
