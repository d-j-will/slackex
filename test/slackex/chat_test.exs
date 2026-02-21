defmodule Slackex.ChatTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "channel lifecycle" do
    test "creating a channel auto-subscribes creator as owner" do
      user = insert(:user)

      assert {:ok, channel} =
               Chat.create_channel(user.id, %{name: "General", description: "General channel"})

      role = Chat.get_role(user.id, channel.id)
      assert role == "owner"
    end

    test "channel slugs are unique and URL-safe" do
      user = insert(:user)

      assert {:ok, channel} = Chat.create_channel(user.id, %{name: "My Cool Channel"})
      assert channel.slug == "my-cool-channel"

      # Duplicate slug rejected
      assert {:error, changeset} = Chat.create_channel(user.id, %{name: "My Cool Channel"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "user can join a public channel" do
      owner = insert(:user)
      joiner = insert(:user)

      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Public Room"})

      assert {:ok, subscription} = Chat.join_channel(joiner.id, channel.id)
      assert subscription.role == "member"
    end

    test "user cannot join a private channel without invite" do
      owner = insert(:user)
      outsider = insert(:user)

      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Secret", is_private: true})

      assert {:error, :unauthorized} = Chat.join_channel(outsider.id, channel.id)
    end

    test "leaving a channel removes subscription" do
      owner = insert(:user)
      member = insert(:user)

      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Leavable"})
      Chat.join_channel(member.id, channel.id)

      assert Chat.get_role(member.id, channel.id) == "member"

      Chat.leave_channel(member.id, channel.id)

      assert is_nil(Chat.get_role(member.id, channel.id))
    end
  end

  describe "messaging behavior" do
    setup do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, channel} = Chat.create_channel(alice.id, %{name: "Test Channel"})
      Chat.join_channel(bob.id, channel.id)
      %{alice: alice, bob: bob, channel: channel}
    end

    test "subscribed user can send a message", %{alice: alice, channel: channel} do
      assert {:ok, message} = Chat.send_message(channel.id, alice.id, "Hello world")
      assert message.content == "Hello world"
      assert message.sender_id == alice.id
      assert message.channel_id == channel.id
    end

    test "messages appear in channel history in order", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      {:ok, _} = Chat.send_message(channel.id, alice.id, "First message")
      {:ok, _} = Chat.send_message(channel.id, bob.id, "Second message")
      {:ok, _} = Chat.send_message(channel.id, alice.id, "Third message")

      messages = Chat.list_messages(channel.id)
      contents = Enum.map(messages, & &1.content)

      # list_messages returns descending order (newest first)
      assert contents == ["Third message", "Second message", "First message"]
    end

    test "non-subscriber cannot send messages", %{channel: channel} do
      outsider = insert(:user)

      assert {:error, :unauthorized} = Chat.send_message(channel.id, outsider.id, "Intruder!")
    end

    test "message content is sanitized (XSS prevention)", %{alice: alice, channel: channel} do
      assert {:ok, message} =
               Chat.send_message(channel.id, alice.id, "<script>alert('xss')</script>Hello")

      refute message.content =~ "<script>"
      assert message.content =~ "Hello"
    end

    test "messages use Snowflake IDs (monotonically increasing)", %{
      alice: alice,
      channel: channel
    } do
      {:ok, msg1} = Chat.send_message(channel.id, alice.id, "First")
      {:ok, msg2} = Chat.send_message(channel.id, alice.id, "Second")
      {:ok, msg3} = Chat.send_message(channel.id, alice.id, "Third")

      assert msg1.id > 0
      assert msg2.id > msg1.id
      assert msg3.id > msg2.id
    end
  end

  describe "unread tracking" do
    setup do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, channel} = Chat.create_channel(alice.id, %{name: "Unread Test"})
      Chat.join_channel(bob.id, channel.id)
      %{alice: alice, bob: bob, channel: channel}
    end

    test "unread count reflects messages since last read", %{
      alice: alice,
      bob: bob,
      channel: channel
    } do
      Chat.mark_as_read(bob.id, channel.id)

      Chat.send_message(channel.id, alice.id, "Msg 1")
      Chat.send_message(channel.id, alice.id, "Msg 2")
      Chat.send_message(channel.id, alice.id, "Msg 3")

      assert Chat.unread_count(bob.id, channel.id) == 3
    end

    test "marking as read resets unread count", %{alice: alice, bob: bob, channel: channel} do
      Chat.send_message(channel.id, alice.id, "Msg A")
      Chat.send_message(channel.id, alice.id, "Msg B")

      assert Chat.unread_count(bob.id, channel.id) == 2

      Chat.mark_as_read(bob.id, channel.id)

      assert Chat.unread_count(bob.id, channel.id) == 0
    end

    test "new channel has zero unread", %{bob: bob, channel: channel} do
      assert Chat.unread_count(bob.id, channel.id) == 0
    end
  end

  describe "direct messages" do
    test "two users can start a DM conversation" do
      alice = insert(:user)
      bob = insert(:user)

      assert {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      assert dm.user_a_id == min(alice.id, bob.id)
      assert dm.user_b_id == max(alice.id, bob.id)
    end

    test "DM conversation is the same regardless of who initiates" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, dm1} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, dm2} = Chat.find_or_create_dm(bob.id, alice.id)

      assert dm1.id == dm2.id
    end

    test "DM messages are persisted and retrievable" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      assert {:ok, message} = Chat.send_dm(dm.id, alice.id, "Hey Bob!")

      assert message.content == "Hey Bob!"
      assert message.dm_conversation_id == dm.id
      assert message.sender_id == alice.id
    end

    test "only DM participants can send messages" do
      alice = insert(:user)
      bob = insert(:user)
      charlie = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      assert {:error, :unauthorized} = Chat.send_dm(dm.id, charlie.id, "Sneaky!")
    end
  end
end
