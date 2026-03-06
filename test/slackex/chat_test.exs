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

  describe "list_user_dm_conversations/1" do
    test "returns DMs with preloaded other_user resolved correctly" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      results = Chat.list_user_dm_conversations(alice.id)

      assert [conversation] = results
      assert conversation.other_user.id == bob.id
      assert conversation.other_user.username
      assert conversation.other_user.display_name
    end

    test "resolves other_user from both sides of the conversation" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      [from_alice] = Chat.list_user_dm_conversations(alice.id)
      [from_bob] = Chat.list_user_dm_conversations(bob.id)

      assert from_alice.other_user.id == bob.id
      assert from_bob.other_user.id == alice.id
    end

    test "returns empty list for user with no DMs" do
      loner = insert(:user)

      assert [] = Chat.list_user_dm_conversations(loner.id)
    end

    test "results ordered by updated_at descending" do
      alice = insert(:user)
      bob = insert(:user)
      charlie = insert(:user)

      {:ok, _dm1} = Chat.find_or_create_dm(alice.id, bob.id)
      Process.sleep(50)
      {:ok, _dm2} = Chat.find_or_create_dm(alice.id, charlie.id)

      results = Chat.list_user_dm_conversations(alice.id)

      assert length(results) == 2
      assert hd(results).updated_at >= List.last(results).updated_at
    end
  end

  describe "DM conversation activity ordering" do
    test "send_dm updates dm_conversation.updated_at" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      before = dm.updated_at
      Process.sleep(10)
      {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "Hello")

      refreshed = Slackex.Repo.get!(Slackex.Chat.DMConversation, dm.id)
      assert DateTime.compare(refreshed.updated_at, before) == :gt
    end

    test "list_user_dm_conversations orders by updated_at desc" do
      alice = insert(:user)
      bob = insert(:user)
      charlie = insert(:user)

      {:ok, dm_bob} = Chat.find_or_create_dm(alice.id, bob.id)
      Process.sleep(10)
      {:ok, dm_charlie} = Chat.find_or_create_dm(alice.id, charlie.id)

      # dm_charlie is newer, should be first
      convos = Chat.list_user_dm_conversations(alice.id)
      assert [first | _] = convos
      assert first.id == dm_charlie.id

      # Now send a message in dm_bob to bump its updated_at
      Process.sleep(10)
      {:ok, _msg} = Chat.send_dm(dm_bob.id, alice.id, "bump")

      convos = Chat.list_user_dm_conversations(alice.id)
      assert [first | _] = convos
      assert first.id == dm_bob.id
    end

    test "returned conversation maps include updated_at field" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      [conversation] = Chat.list_user_dm_conversations(alice.id)
      assert Map.has_key?(conversation, :updated_at)
      assert %DateTime{} = conversation.updated_at
    end
  end

  describe "count_members/1" do
    test "returns correct subscriber count for a channel" do
      owner = insert(:user)
      member = insert(:user)

      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Counting"})
      Chat.join_channel(member.id, channel.id)

      assert Chat.count_members(channel.id) == 2
    end

    test "returns 1 for channel with only the creator" do
      owner = insert(:user)
      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Solo"})

      assert Chat.count_members(channel.id) == 1
    end
  end

  describe "list_public_channels/1" do
    test "returns all public channels with member_count when called with no opts" do
      owner = insert(:user)
      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Open"})

      channels = Chat.list_public_channels()
      assert [found] = channels
      assert found.id == channel.id
      assert found.member_count == 1
    end

    test "excludes channels the given user is subscribed to" do
      owner = insert(:user)
      browser = insert(:user)

      {:ok, joined_channel} = Chat.create_channel(owner.id, %{name: "Already Joined"})
      {:ok, other_channel} = Chat.create_channel(owner.id, %{name: "Not Joined"})
      Chat.join_channel(browser.id, joined_channel.id)

      channels = Chat.list_public_channels(exclude_member: browser.id)
      channel_ids = Enum.map(channels, & &1.id)

      refute joined_channel.id in channel_ids
      assert other_channel.id in channel_ids
    end

    test "private channels never appear in results" do
      owner = insert(:user)
      {:ok, _private} = Chat.create_channel(owner.id, %{name: "Secret Room", is_private: true})
      {:ok, public} = Chat.create_channel(owner.id, %{name: "Open Room"})

      channels = Chat.list_public_channels()
      channel_ids = Enum.map(channels, & &1.id)

      assert public.id in channel_ids
      refute Enum.any?(channels, fn c -> c.name == "Secret Room" end)
    end

    test "each channel includes member_count" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, channel} = Chat.create_channel(owner.id, %{name: "Popular"})
      Chat.join_channel(member.id, channel.id)

      [found] = Chat.list_public_channels()
      assert found.member_count == 2
    end
  end

  describe "dm_conversation updated_at field" do
    test "DMConversation has updated_at populated on creation" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      refreshed = Slackex.Repo.get!(Slackex.Chat.DMConversation, dm.id)
      assert refreshed.updated_at != nil
      assert %DateTime{} = refreshed.updated_at
    end

    test "list_user_dm_conversations includes updated_at" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      [conversation] = Chat.list_user_dm_conversations(alice.id)
      assert Map.has_key?(conversation, :updated_at)
      assert conversation.updated_at != nil
    end
  end

  describe "find_or_create_dm/2 PubSub broadcast" do
    test "broadcasts {:dm_conversation_new, dm} to both user topics when creating a new DM" do
      alice = insert(:user)
      bob = insert(:user)

      # Subscribe to both user topics
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{alice.id}")
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{bob.id}")

      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Both participants should receive the broadcast
      assert_receive {:dm_conversation_new, ^dm}
      assert_receive {:dm_conversation_new, ^dm}
    end

    test "does NOT broadcast when returning an existing DM" do
      alice = insert(:user)
      bob = insert(:user)

      # Create the DM first
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Subscribe after creation to only capture broadcasts from the second call
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{alice.id}")
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{bob.id}")

      # Reopen the existing DM
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # No broadcast should occur
      refute_receive {:dm_conversation_new, _}
    end
  end

  describe "get_dm_conversation!/1" do
    test "returns DM conversation by ID" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      found = Chat.get_dm_conversation!(dm.id)

      assert found.id == dm.id
    end

    test "raises when DM conversation not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_dm_conversation!(0)
      end
    end
  end
end
