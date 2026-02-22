defmodule SlackexWeb.DMChannelTest do
  use SlackexWeb.ChannelCase, async: false

  alias Slackex.Accounts.Auth
  alias Slackex.Chat

  setup do
    alice = insert(:user)
    bob = insert(:user)
    token = Auth.generate_api_token(alice)
    {:ok, socket} = connect(SlackexWeb.UserSocket, %{"token" => token})
    {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

    %{socket: socket, alice: alice, bob: bob, dm: dm}
  end

  describe "DMChannel join" do
    test "DM participant can join", %{socket: socket, dm: dm} do
      assert {:ok, reply, _socket} = subscribe_and_join(socket, "dm:#{dm.id}", %{})
      assert %{messages: messages} = reply
      assert is_list(messages)
    end

    test "non-participant cannot join", %{dm: dm} do
      charlie = insert(:user)
      charlie_token = Auth.generate_api_token(charlie)
      {:ok, charlie_socket} = connect(SlackexWeb.UserSocket, %{"token" => charlie_token})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(charlie_socket, "dm:#{dm.id}", %{})
    end

    test "join returns recent DM messages", %{socket: socket, dm: dm, alice: alice} do
      {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "Hey Bob!")

      assert {:ok, reply, _socket} = subscribe_and_join(socket, "dm:#{dm.id}", %{})
      assert [%{content: "Hey Bob!"} | _] = reply.messages
    end
  end

  describe "DMChannel messaging" do
    setup %{socket: socket, dm: dm} do
      {:ok, _reply, socket} = subscribe_and_join(socket, "dm:#{dm.id}", %{})
      %{socket: socket}
    end

    test "sending a DM is pushed back to the sender", %{socket: socket} do
      ref = push(socket, "new_message", %{"content" => "Direct message test"})
      assert_reply ref, :ok
      assert_push "message.new", %{content: "Direct message test"}
    end

    test "message payload includes sender_id and string ID", %{socket: socket, alice: alice} do
      ref = push(socket, "new_message", %{"content" => "Hello"})
      assert_reply ref, :ok
      assert_push "message.new", %{id: id, sender_id: sender_id}
      assert is_binary(id)
      assert sender_id == to_string(alice.id)
    end
  end
end
