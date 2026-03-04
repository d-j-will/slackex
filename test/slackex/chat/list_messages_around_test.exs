defmodule Slackex.Chat.ListMessagesAroundTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  # Helper: creates a channel with a subscribed owner and sends N messages,
  # returning {channel, user, messages} where messages are ordered by id ASC.
  defp setup_channel_with_messages(count) do
    user = insert(:user)
    channel = insert(:channel, creator: user)
    _sub = insert(:subscription, user: user, channel: channel, role: "owner")

    messages =
      for _i <- 1..count do
        {:ok, msg} = Chat.send_message(channel.id, user.id, "msg")
        msg
      end

    {channel, user, Enum.sort_by(messages, & &1.id)}
  end

  describe "list_messages_around/3 with {:channel, channel_id}" do
    test "returns messages centered around the target message" do
      {channel, _user, messages} = setup_channel_with_messages(11)

      # Target the middle message (index 5, so 5 before and 5 after)
      target = Enum.at(messages, 5)

      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 11)

      result_ids = Enum.map(result, & &1.id)
      expected_ids = Enum.map(messages, & &1.id)

      assert result_ids == expected_ids
    end

    test "preloads sender on all returned messages" do
      {channel, user, messages} = setup_channel_with_messages(3)

      target = Enum.at(messages, 1)
      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 3)

      assert Enum.all?(result, fn msg ->
               msg.sender != nil and msg.sender.id == user.id
             end)
    end

    test "returns messages ordered by id ASC" do
      {channel, _user, messages} = setup_channel_with_messages(7)

      target = Enum.at(messages, 3)
      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 7)

      ids = Enum.map(result, & &1.id)
      assert ids == Enum.sort(ids)
    end

    test "handles target being the newest message" do
      {channel, _user, messages} = setup_channel_with_messages(5)

      target = List.last(messages)
      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 5)

      # Should return the target plus up to half_page messages before it
      assert Enum.any?(result, &(&1.id == target.id))
      assert Enum.map(result, & &1.id) == Enum.sort(Enum.map(result, & &1.id))
    end

    test "handles target being the oldest message" do
      {channel, _user, messages} = setup_channel_with_messages(5)

      target = List.first(messages)
      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 5)

      # Should return the target plus up to half_page messages after it
      assert Enum.any?(result, &(&1.id == target.id))
      assert Enum.map(result, & &1.id) == Enum.sort(Enum.map(result, & &1.id))
    end

    test "returns empty list when target does not exist" do
      channel = insert(:channel)

      result = Chat.list_messages_around({:channel, channel.id}, 999_999_999_999, limit: 10)

      assert result == []
    end

    test "excludes soft-deleted messages" do
      {channel, user, messages} = setup_channel_with_messages(5)

      target = Enum.at(messages, 2)

      # Soft-delete a neighbor message
      neighbor = Enum.at(messages, 3)
      {:ok, _deleted} = Chat.delete_message(neighbor.id, user.id)

      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 5)
      result_ids = Enum.map(result, & &1.id)

      refute neighbor.id in result_ids
      assert target.id in result_ids
    end

    test "returns empty list when target itself is deleted" do
      {channel, user, messages} = setup_channel_with_messages(3)

      target = Enum.at(messages, 1)
      {:ok, _deleted} = Chat.delete_message(target.id, user.id)

      result = Chat.list_messages_around({:channel, channel.id}, target.id, limit: 3)

      assert result == []
    end
  end

  describe "list_messages_around/3 with {:dm, dm_conversation_id}" do
    test "returns messages centered around target in a DM conversation" do
      dm = insert(:dm_conversation)

      messages =
        for _i <- 1..7 do
          {:ok, msg} = Chat.send_dm(dm.id, dm.user_a_id, "dm msg")
          msg
        end

      messages = Enum.sort_by(messages, & &1.id)
      target = Enum.at(messages, 3)

      result = Chat.list_messages_around({:dm, dm.id}, target.id, limit: 7)

      result_ids = Enum.map(result, & &1.id)
      expected_ids = Enum.map(messages, & &1.id)

      assert result_ids == expected_ids
    end

    test "returns empty list when target does not exist in DM" do
      dm = insert(:dm_conversation)

      result = Chat.list_messages_around({:dm, dm.id}, 999_999_999_999, limit: 10)

      assert result == []
    end
  end

  describe "list_messages_around/3 defaults" do
    test "uses default limit of 50 when not specified" do
      {channel, _user, messages} = setup_channel_with_messages(3)

      target = Enum.at(messages, 1)

      # Call without opts -- should still work with default limit
      result = Chat.list_messages_around({:channel, channel.id}, target.id)

      assert length(result) == 3
    end
  end
end
