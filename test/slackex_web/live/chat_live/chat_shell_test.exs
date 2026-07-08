defmodule SlackexWeb.ChatLive.ChatShellTest do
  use Slackex.DataCase, async: false

  import Slackex.TestFactory

  alias Slackex.Cache.Redis, as: RedisCache
  alias SlackexWeb.ChatLive.ChatShell

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    FunWithFlags.enable(:catchup_on_reconnect)
    :ok
  end

  describe "run/2" do
    test "first connected mount reconciles unread counts without flashing catchup" do
      user = insert(:user)
      other = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:subscription, user: other, channel: channel)

      msg1 = insert(:message, channel: channel, sender: other, content: "missed 1")
      msg2 = insert(:message, channel: channel, sender: other, content: "missed 2")
      _msg3 = insert(:message, channel: channel, sender: other, content: "missed 3")

      insert(:read_cursor, user: user, channel: channel, last_read_message_id: msg1.id)
      RedisCache.set_read_cursor(user.id, {:channel, channel.id}, msg2.id)

      assert {:ok, shell} = ChatShell.run(user, connected?: true, mode: :first_mount)
      assert shell.catchup_summary == nil
      assert shell.unread_counts.channel_counts[channel.id] == 1
    end

    test "reconnect mode overlays unread counts from catchup" do
      user = insert(:user)
      other = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:subscription, user: other, channel: channel)

      msg1 = insert(:message, channel: channel, sender: other, content: "missed 1")
      msg2 = insert(:message, channel: channel, sender: other, content: "missed 2")
      _msg3 = insert(:message, channel: channel, sender: other, content: "missed 3")

      insert(:read_cursor, user: user, channel: channel, last_read_message_id: msg1.id)
      RedisCache.set_read_cursor(user.id, {:channel, channel.id}, msg2.id)

      assert {:ok, shell} = ChatShell.run(user, connected?: true, mode: :reconnect)
      assert shell.unread_counts.channel_counts[channel.id] == 1
      assert shell.catchup_summary == "1 new message while you were away"
      assert shell.runtime_plan == %{channel_ids: [channel.id], dm_ids: []}
    end
  end

  describe "mount_mode/2" do
    test "disconnected mounts are first mounts" do
      assert ChatShell.mount_mode(false, nil) == :first_mount
    end

    test "_mounts zero is a first connected mount" do
      assert ChatShell.mount_mode(true, %{"_mounts" => 0}) == :first_mount
      assert ChatShell.mount_mode(true, %{"_mounts" => "0"}) == :first_mount
    end

    test "_mounts greater than zero is a reconnect" do
      assert ChatShell.mount_mode(true, %{"_mounts" => 1}) == :reconnect
      assert ChatShell.mount_mode(true, %{"_mounts" => "2"}) == :reconnect
    end
  end
end
