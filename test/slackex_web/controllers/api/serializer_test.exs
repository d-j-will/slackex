defmodule SlackexWeb.SerializerTest do
  # Pure unit tests — no database interaction needed.
  use ExUnit.Case, async: true

  alias SlackexWeb.API.ChannelJSON
  alias SlackexWeb.API.MessageJSON
  alias SlackexWeb.API.UserJSON

  @inserted_at ~U[2024-01-15 10:00:00.000000Z]
  @updated_at ~U[2024-01-15 11:00:00.000000Z]

  describe "UserJSON" do
    @valid_user %{
      id: 987_654_321,
      username: "alice",
      display_name: "Alice Smith",
      avatar_url: "https://example.com/avatar.png",
      status: "online"
    }

    test "serializes all required user fields" do
      result = UserJSON.data(@valid_user)

      assert result.username == "alice"
      assert result.display_name == "Alice Smith"
      assert result.avatar_url == "https://example.com/avatar.png"
      assert result.status == "online"
    end

    test "id is serialized as string" do
      result = UserJSON.data(@valid_user)
      assert result.id == "987654321"
      assert is_binary(result.id)
    end

    test "does not include hashed_password or email" do
      user_with_sensitive = Map.merge(@valid_user, %{hashed_password: "secret", email: "a@b.com"})
      result = UserJSON.data(user_with_sensitive)
      refute Map.has_key?(result, :hashed_password)
      refute Map.has_key?(result, :email)
    end
  end

  describe "ChannelJSON" do
    @valid_channel %{
      id: 111_222_333,
      name: "general",
      slug: "general",
      description: "General discussion",
      is_private: false,
      creator_id: 444_555_666,
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    test "serializes all required channel fields" do
      result = ChannelJSON.data(@valid_channel)

      assert result.name == "general"
      assert result.slug == "general"
      assert result.description == "General discussion"
      assert result.is_private == false
      assert result.inserted_at == @inserted_at
      assert result.updated_at == @updated_at
    end

    test "id and creator_id are serialized as strings" do
      result = ChannelJSON.data(@valid_channel)
      assert result.id == "111222333"
      assert result.creator_id == "444555666"
      assert is_binary(result.id)
      assert is_binary(result.creator_id)
    end
  end

  describe "MessageJSON" do
    @valid_sender %{
      id: 100,
      username: "bob",
      display_name: "Bob Jones",
      avatar_url: nil,
      status: "offline"
    }

    @valid_message %{
      id: 123_456_789_012_345_678,
      content: "Hello channel!",
      sender: @valid_sender,
      channel_id: 111_222_333,
      dm_conversation_id: nil,
      inserted_at: @inserted_at
    }

    test "serializes message with all required fields" do
      result = MessageJSON.data(@valid_message)

      assert result.content == "Hello channel!"
      assert result.inserted_at == @inserted_at
    end

    test "message id is serialized as string" do
      result = MessageJSON.data(@valid_message)
      assert result.id == "123456789012345678"
      assert is_binary(result.id)
    end

    test "channel_id is serialized as string when present" do
      result = MessageJSON.data(@valid_message)
      assert result.channel_id == "111222333"
      assert is_binary(result.channel_id)
    end

    test "dm_conversation_id is nil when not present" do
      result = MessageJSON.data(@valid_message)
      assert is_nil(result.dm_conversation_id)
    end

    test "dm_conversation_id is serialized as string when present" do
      dm_message = %{@valid_message | channel_id: nil, dm_conversation_id: 999_888_777}
      result = MessageJSON.data(dm_message)
      assert result.dm_conversation_id == "999888777"
      assert is_binary(result.dm_conversation_id)
    end

    test "includes sender info via UserJSON" do
      result = MessageJSON.data(@valid_message)
      assert result.sender.username == "bob"
      assert result.sender.id == "100"
    end

    test "handles nil sender gracefully" do
      nil_sender_message = %{@valid_message | sender: nil}
      result = MessageJSON.data(nil_sender_message)
      # Expected: sender should be nil (or a placeholder) rather than crashing
      assert is_nil(result.sender)
    end
  end
end
