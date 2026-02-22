defmodule Slackex.Search.HistoryLoaderTest do
  use Slackex.DataCase, async: false

  alias Slackex.Cache.Local
  alias Slackex.Chat
  alias Slackex.Search.HistoryLoader

  setup do
    :ets.delete_all_objects(:slackex_message_cache)
    :ok
  end

  describe "recent/2 - cache hit" do
    test "returns cached messages in chronological order without hitting DB" do
      target = {:channel, 999_999}
      msg1 = %{id: 1, content: "cached first"}
      msg2 = %{id: 2, content: "cached second"}

      Local.put_message(target, msg1)
      Local.put_message(target, msg2)

      assert {:ok, messages} = HistoryLoader.recent(target)
      assert length(messages) == 2
      assert hd(messages).id == 1
      assert List.last(messages).id == 2
    end

    test "returns cached dm messages in chronological order" do
      target = {:dm, 999_998}
      msg1 = %{id: 10, content: "dm first"}
      msg2 = %{id: 20, content: "dm second"}

      Local.put_message(target, msg1)
      Local.put_message(target, msg2)

      assert {:ok, messages} = HistoryLoader.recent(target)
      assert Enum.map(messages, & &1.id) == [10, 20]
    end
  end

  describe "recent/2 - cache miss (channel)" do
    test "queries DB and returns messages in chronological order" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-channel-1"})
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "First")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Second")

      target = {:channel, channel.id}

      assert {:ok, messages} = HistoryLoader.recent(target, 50)
      assert length(messages) == 2
      assert Enum.map(messages, & &1.id) == [msg1.id, msg2.id]
    end

    test "backfills cache after DB query" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-channel-2"})
      {:ok, _} = Chat.send_message(channel.id, user.id, "Hello")

      target = {:channel, channel.id}

      {:ok, _} = HistoryLoader.recent(target, 50)

      assert {:ok, cached} = Local.get_messages(target)
      assert length(cached) == 1
    end

    test "returns empty list when channel has no messages" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-channel-empty"})

      assert {:ok, []} = HistoryLoader.recent({:channel, channel.id})
    end
  end

  describe "recent/2 - cache miss (dm)" do
    test "queries DB and returns DM messages in chronological order" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, msg1} = Chat.send_dm(dm.id, alice.id, "Hey")
      {:ok, msg2} = Chat.send_dm(dm.id, bob.id, "Hi back")

      target = {:dm, dm.id}

      assert {:ok, messages} = HistoryLoader.recent(target, 50)
      assert Enum.map(messages, & &1.id) == [msg1.id, msg2.id]
    end

    test "returns empty list when DM has no messages" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      assert {:ok, []} = HistoryLoader.recent({:dm, dm.id})
    end
  end

  describe "before/3 (channel)" do
    test "returns messages before the given id in chronological order" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-before-1"})
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "First")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Second")
      {:ok, msg3} = Chat.send_message(channel.id, user.id, "Third")

      target = {:channel, channel.id}

      assert {:ok, messages} = HistoryLoader.before(target, msg3.id, 50)
      assert Enum.map(messages, & &1.id) == [msg1.id, msg2.id]
      refute msg3.id in Enum.map(messages, & &1.id)
    end

    test "returns empty list when no messages before given id" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-before-empty"})
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "Only")

      assert {:ok, []} = HistoryLoader.before({:channel, channel.id}, msg1.id, 50)
    end

    test "respects the limit parameter" do
      user = insert(:user)
      {:ok, channel} = Chat.create_channel(user.id, %{name: "hist-before-limit"})

      {:ok, _msg1} = Chat.send_message(channel.id, user.id, "One")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "Two")
      {:ok, msg3} = Chat.send_message(channel.id, user.id, "Three")
      {:ok, msg4} = Chat.send_message(channel.id, user.id, "Four")

      target = {:channel, channel.id}

      assert {:ok, messages} = HistoryLoader.before(target, msg4.id, 2)
      assert length(messages) == 2
      assert Enum.map(messages, & &1.id) == [msg2.id, msg3.id]
    end
  end

  describe "before/3 (dm)" do
    test "returns DM messages before the given id in chronological order" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)
      {:ok, msg1} = Chat.send_dm(dm.id, alice.id, "First")
      {:ok, msg2} = Chat.send_dm(dm.id, bob.id, "Second")
      {:ok, msg3} = Chat.send_dm(dm.id, alice.id, "Third")

      target = {:dm, dm.id}

      assert {:ok, messages} = HistoryLoader.before(target, msg3.id, 50)
      assert Enum.map(messages, & &1.id) == [msg1.id, msg2.id]
    end
  end
end
