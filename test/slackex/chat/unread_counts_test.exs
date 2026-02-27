defmodule Slackex.Chat.UnreadCountsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "batch_unread_counts/1" do
    setup do
      alice = insert(:user)
      bob = insert(:user)

      # Create two channels with alice as owner, bob as member
      {:ok, channel_a} = Chat.create_channel(alice.id, %{name: "Channel A"})
      Chat.join_channel(bob.id, channel_a.id)

      {:ok, channel_b} = Chat.create_channel(alice.id, %{name: "Channel B"})
      Chat.join_channel(bob.id, channel_b.id)

      # Create a DM conversation between alice and bob
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      %{alice: alice, bob: bob, channel_a: channel_a, channel_b: channel_b, dm: dm}
    end

    test "returns correct channel and DM unread counts in a single batch", %{
      alice: alice,
      bob: bob,
      channel_a: channel_a,
      channel_b: channel_b,
      dm: dm
    } do
      # Bob marks both channels as read
      Chat.mark_as_read(bob.id, channel_a.id)
      Chat.mark_as_read(bob.id, channel_b.id)

      # Alice sends messages after bob's read cursors
      {:ok, _} = Chat.send_message(channel_a.id, alice.id, "New in A - 1")
      {:ok, _} = Chat.send_message(channel_a.id, alice.id, "New in A - 2")
      {:ok, _} = Chat.send_message(channel_b.id, alice.id, "New in B - 1")

      # Alice sends DM messages
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM msg 1")
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM msg 2")
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM msg 3")

      result = Chat.batch_unread_counts(bob.id)

      assert %{channel_counts: channel_counts, dm_counts: dm_counts} = result

      # Channel counts match per-channel unread_count/2
      assert Map.get(channel_counts, channel_a.id) == 2
      assert Map.get(channel_counts, channel_b.id) == 1

      # DM counts reflect messages after cursor (bob has no DM cursor, so all 3)
      assert Map.get(dm_counts, dm.id) == 3
    end

    test "returns zero counts for conversations with no unread messages", %{
      bob: bob,
      channel_a: channel_a,
      channel_b: channel_b,
      dm: dm
    } do
      # No messages sent, so everything should be zero
      result = Chat.batch_unread_counts(bob.id)

      assert %{channel_counts: channel_counts, dm_counts: dm_counts} = result

      # Zero counts present (not absent keys)
      assert Map.get(channel_counts, channel_a.id) == 0
      assert Map.get(channel_counts, channel_b.id) == 0
      assert Map.get(dm_counts, dm.id) == 0
    end

    test "channel counts match per-channel Chat.unread_count/2 for same user", %{
      alice: alice,
      bob: bob,
      channel_a: channel_a,
      channel_b: channel_b
    } do
      Chat.mark_as_read(bob.id, channel_a.id)

      {:ok, _} = Chat.send_message(channel_a.id, alice.id, "After read")
      {:ok, _} = Chat.send_message(channel_b.id, alice.id, "Never read")

      %{channel_counts: channel_counts} = Chat.batch_unread_counts(bob.id)

      assert Map.get(channel_counts, channel_a.id) == Chat.unread_count(bob.id, channel_a.id)
      assert Map.get(channel_counts, channel_b.id) == Chat.unread_count(bob.id, channel_b.id)
    end

    test "returns counts for all subscribed channels and DMs in batch", %{bob: bob, dm: dm} do
      # Create additional channels to increase conversation count
      owner = insert(:user)

      extra_channels =
        for i <- 1..5 do
          {:ok, ch} = Chat.create_channel(owner.id, %{name: "Extra #{i}"})
          Chat.join_channel(bob.id, ch.id)
          ch
        end

      # Create additional DM conversations
      extra_dms =
        for _i <- 1..3 do
          other = insert(:user)
          {:ok, extra_dm} = Chat.find_or_create_dm(bob.id, other.id)
          extra_dm
        end

      result = Chat.batch_unread_counts(bob.id)

      assert %{channel_counts: channel_counts, dm_counts: dm_counts} = result

      # All 7 channels present (2 from setup + 5 extra)
      assert map_size(channel_counts) == 7

      for ch <- extra_channels do
        assert Map.has_key?(channel_counts, ch.id)
      end

      # All 4 DMs present (1 from setup + 3 extra)
      assert map_size(dm_counts) == 4
      assert Map.has_key?(dm_counts, dm.id)

      for extra_dm <- extra_dms do
        assert Map.has_key?(dm_counts, extra_dm.id)
      end
    end

    test "DM counts reflect messages after the user read cursor per DM conversation", %{
      alice: alice,
      bob: bob,
      dm: dm
    } do
      # Send some DM messages
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM 1")
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM 2")

      # Bob marks DM as read
      Chat.mark_dm_as_read(bob.id, dm.id)

      # Alice sends more messages after bob's DM read cursor
      {:ok, _} = Chat.send_dm(dm.id, alice.id, "DM 3")

      %{dm_counts: dm_counts} = Chat.batch_unread_counts(bob.id)

      assert Map.get(dm_counts, dm.id) == 1
    end
  end

end
