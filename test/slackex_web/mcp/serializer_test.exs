defmodule SlackexWeb.MCP.SerializerTest do
  use Slackex.DataCase, async: true

  alias SlackexWeb.MCP.Serializer

  describe "channel/2" do
    test "serializes channel with member count, no internal fields" do
      user = insert(:user)
      channel = insert(:channel, creator: user, name: "general", slug: "general")
      result = Serializer.channel(channel, 42)

      assert result.id == to_string(channel.id)
      assert result.name == "general"
      assert result.slug == "general"
      assert result.member_count == 42
      assert Map.has_key?(result, :inserted_at)
      refute Map.has_key?(result, :creator)
      refute Map.has_key?(result, :creator_id)
      refute Map.has_key?(result, :__struct__)
      refute Map.has_key?(result, :__meta__)
    end
  end

  describe "message/1" do
    test "serializes message with string IDs, no encrypted content leak" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      insert(:subscription, user: user, channel: channel)

      {:ok, msg} = Slackex.Chat.send_message(channel.id, user.id, "hello world")
      db_msg = Slackex.Chat.get_message!(msg.id)
      result = Serializer.message(db_msg)

      assert result.id == to_string(db_msg.id)
      assert result.channel_id == to_string(db_msg.channel_id)
      assert result.sender_id == to_string(db_msg.sender_id)
      assert result.content == "hello world"
      assert Map.has_key?(result, :inserted_at)
      refute Map.has_key?(result, :__struct__)
      refute Map.has_key?(result, :search_content)
      refute Map.has_key?(result, :embedding)
    end
  end

  describe "message_from_map/1" do
    test "serializes a ChannelServer plain map" do
      now = DateTime.utc_now()

      msg_map = %{
        id: 12_345,
        content: "from channel server",
        sender_id: 999,
        channel_id: 100,
        inserted_at: now
      }

      result = Serializer.message_from_map(msg_map)

      assert result.id == "12345"
      assert result.content == "from channel server"
      assert result.sender_id == "999"
      assert result.channel_id == "100"
      assert result.reply_count == 0
      assert result.edited_at == nil
    end
  end

  describe "user/1" do
    test "serializes user with safe fields only" do
      user = insert(:user, username: "testbot", display_name: "Test Bot", is_bot: true)
      result = Serializer.user(user)

      assert result.id == to_string(user.id)
      assert result.username == "testbot"
      assert result.display_name == "Test Bot"
      assert result.is_bot == true
      refute Map.has_key?(result, :email)
      refute Map.has_key?(result, :email_hash)
      refute Map.has_key?(result, :hashed_password)
    end
  end

  describe "messages/1" do
    test "serializes a list of messages" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      insert(:subscription, user: user, channel: channel)

      {:ok, msg1} = Slackex.Chat.send_message(channel.id, user.id, "first")
      {:ok, msg2} = Slackex.Chat.send_message(channel.id, user.id, "second")

      db_msgs = [Slackex.Chat.get_message!(msg1.id), Slackex.Chat.get_message!(msg2.id)]
      results = Serializer.messages(db_msgs)

      assert length(results) == 2
      assert Enum.all?(results, &is_map/1)
    end
  end
end
