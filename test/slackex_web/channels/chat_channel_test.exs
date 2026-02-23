defmodule SlackexWeb.ChatChannelTest do
  use SlackexWeb.ChannelCase, async: false

  alias Slackex.Accounts.Auth
  alias Slackex.Chat
  alias Slackex.Notifications.OnlineTracker

  setup do
    user = insert(:user)
    token = Auth.generate_api_token(user)
    {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => token})

    {:ok, channel} = Chat.create_channel(user.id, %{name: "test-channel", description: "Test"})

    %{socket: socket, user: user, channel: channel}
  end

  describe "UserSocket connect" do
    test "valid JWT token connects successfully", %{user: user} do
      token = Auth.generate_api_token(user)
      assert {:ok, _socket} = connect(SlackexWeb.UserSocket, %{"token" => token})
    end

    test "invalid token rejects connection" do
      assert :error = connect(SlackexWeb.UserSocket, %{"token" => "invalid.bad.token"})
    end

    test "missing token rejects connection" do
      assert :error = connect(SlackexWeb.UserSocket, %{})
    end

    test "marks user online in Redis on connect", %{user: user} do
      Redix.command!(:redix_0, ["DEL", "online:#{user.id}"])
      token = Auth.generate_api_token(user)
      {:ok, _socket} = connect(SlackexWeb.UserSocket, %{"token" => token})
      assert OnlineTracker.online?(user.id)
    end
  end

  describe "ChatChannel join" do
    test "subscriber can join their channel", %{socket: socket, channel: channel} do
      assert {:ok, reply, _socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      assert %{messages: messages} = reply
      assert is_list(messages)
    end

    test "join returns recent message history", %{socket: socket, channel: channel, user: user} do
      {:ok, _msg} = Chat.send_message(channel.id, user.id, "Hello World")

      assert {:ok, reply, _socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      assert [%{content: "Hello World"} | _] = reply.messages
    end

    test "malformed topic ID returns invalid_topic error", %{socket: socket} do
      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, "chat:abc", %{})
    end

    test "empty topic ID returns invalid_topic error", %{socket: socket} do
      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, "chat:", %{})
    end

    test "non-subscriber cannot join channel", %{socket: socket} do
      other_user = insert(:user)

      {:ok, other_channel} =
        Chat.create_channel(other_user.id, %{name: "other-channel", description: "Other"})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "chat:#{other_channel.id}", %{})
    end

    test "joining marks channel as read", %{socket: socket, channel: channel, user: user} do
      {:ok, _msg} = Chat.send_message(channel.id, user.id, "Unread message")
      assert Chat.unread_count(user.id, channel.id) == 1

      {:ok, _reply, _socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      assert Chat.unread_count(user.id, channel.id) == 0
    end
  end

  describe "ChatChannel messaging" do
    setup %{socket: socket, channel: channel} do
      {:ok, _reply, socket} = subscribe_and_join(socket, "chat:#{channel.id}", %{})
      %{socket: socket}
    end

    test "sending a message is pushed back to the sender", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => "Test message"})
      assert_reply ref, :ok
      assert_push "message.new", %{content: "Test message"}
    end

    test "message payload includes sender_id and content", %{socket: socket, user: user} do
      ref = push(socket, "new_message", %{"content" => "Hello"})
      assert_reply ref, :ok
      assert_push "message.new", %{content: "Hello", sender_id: sender_id}
      assert sender_id == to_string(user.id)
    end

    test "message ID is serialized as string", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => "ID test"})
      assert_reply ref, :ok
      assert_push "message.new", %{id: id}
      assert is_binary(id)
    end
  end
end
