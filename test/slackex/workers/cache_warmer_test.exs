defmodule Slackex.Workers.CacheWarmerTest do
  use Slackex.DataCase, async: false

  import Slackex.Factory

  alias Slackex.Chat
  alias Slackex.Messaging.ChannelSupervisor
  alias Slackex.Workers.CacheWarmer

  setup do
    on_exit(fn ->
      # Clean up any ChannelServer processes started during tests
      ChannelSupervisor
      |> Horde.DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        Horde.DynamicSupervisor.terminate_child(ChannelSupervisor, pid)
      end)
    end)

    :ok
  end

  describe "perform/1" do
    test "starts ChannelServers for active channels" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel, role: "member")

      # Insert a message within the last hour
      insert(:message, channel: channel, sender: user)

      job = %Oban.Job{args: %{}, id: 1, worker: "Slackex.Workers.CacheWarmer"}
      assert :ok = CacheWarmer.perform(job)

      # The ChannelServer for this channel should now be running
      assert {:ok, pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      assert is_pid(pid)
    end

    test "does not start ChannelServers for inactive channels" do
      _channel = insert(:channel)

      # Count children before
      before_count =
        ChannelSupervisor
        |> Horde.DynamicSupervisor.which_children()
        |> length()

      job = %Oban.Job{args: %{}, id: 1, worker: "Slackex.Workers.CacheWarmer"}
      assert :ok = CacheWarmer.perform(job)

      after_count =
        ChannelSupervisor
        |> Horde.DynamicSupervisor.which_children()
        |> length()

      assert after_count == before_count
    end

    test "returns :ok with no active channels" do
      job = %Oban.Job{args: %{}, id: 1, worker: "Slackex.Workers.CacheWarmer"}
      assert :ok = CacheWarmer.perform(job)
    end
  end

  describe "Chat.list_active_channels/1" do
    test "returns channels with recent message activity" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel, role: "member")
      insert(:message, channel: channel, sender: user)

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Chat.list_active_channels(since: since)

      assert Enum.any?(result, fn c -> c.id == channel.id end)
    end

    test "excludes channels with no messages" do
      _channel = insert(:channel)

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Chat.list_active_channels(since: since)

      assert result == []
    end

    test "excludes channels with only old messages" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel, role: "member")

      # Insert a message with an inserted_at in the past (2 hours ago)
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      insert(:message,
        channel: channel,
        sender: user,
        inserted_at: DateTime.truncate(two_hours_ago, :microsecond)
      )

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Chat.list_active_channels(since: since)

      refute Enum.any?(result, fn c -> c.id == channel.id end)
    end

    test "requires :since option" do
      assert_raise KeyError, fn ->
        Chat.list_active_channels([])
      end
    end
  end
end
