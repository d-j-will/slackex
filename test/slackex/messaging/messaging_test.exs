defmodule Slackex.MessagingTest do
  # async: false — shares the global ChannelRegistry and ChannelSupervisor
  use Slackex.DataCase, async: false

  alias Slackex.Messaging
  alias Slackex.Messaging.{ChannelServer, ChannelSupervisor}

  # Stop a ChannelServer by target tuple if one is running.
  defp stop_server(target) do
    case Registry.lookup(Slackex.Messaging.ChannelRegistry, target) do
      [{pid, _}] ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(ChannelSupervisor, pid)

      [] ->
        :ok
    end
  end

  describe "send_message/4" do
    test "auto-starts a ChannelServer and delivers the message" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      assert {:ok, msg} = Messaging.send_message(channel.id, user.id, "hello")
      assert msg.content == "hello"
      assert msg.sender_id == user.id
    end

    test "returns {:error, :unauthorized} for a user with no channel role" do
      owner = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(owner.id, %{name: "m-#{System.unique_integer()}"})

      outsider = insert(:user)

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      assert {:error, :unauthorized} = Messaging.send_message(channel.id, outsider.id, "hi")
    end

    test "reuses the running ChannelServer on subsequent calls" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      {:ok, _} = Messaging.send_message(channel.id, user.id, "first")
      count_after_first = Messaging.channel_count()

      {:ok, _} = Messaging.send_message(channel.id, user.id, "second")
      assert Messaging.channel_count() == count_after_first
    end
  end

  describe "send_dm/4" do
    test "delivers a DM from a conversation participant" do
      dm = insert(:dm_conversation)
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      assert {:ok, msg} = Messaging.send_dm(dm.id, dm.user_a.id, "hey")
      assert msg.content == "hey"
      assert msg.sender_id == dm.user_a.id
    end

    test "returns {:error, :unauthorized} for a non-participant sender" do
      dm = insert(:dm_conversation)
      outsider = insert(:user)

      assert {:error, :unauthorized} = Messaging.send_dm(dm.id, outsider.id, "intruder")
    end

    test "both participants can send messages" do
      dm = insert(:dm_conversation)
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      assert {:ok, _} = Messaging.send_dm(dm.id, dm.user_a.id, "from a")
      assert {:ok, _} = Messaging.send_dm(dm.id, dm.user_b.id, "from b")
    end
  end

  describe "get_recent_messages/2" do
    test "returns messages from the running ChannelServer" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.send_message(channel.id, user.id, "cached")
      messages = Messaging.get_recent_messages(channel.id, 50)

      assert Enum.any?(messages, &(Map.get(&1, :content) == "cached"))
    end

    test "falls back to DB query when no ChannelServer is running" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      # No server started — falls through to Chat.list_messages
      result = Messaging.get_recent_messages(channel.id, 10)
      assert is_list(result)
    end
  end

  describe "subscribe_channel/1 and unsubscribe_channel/1" do
    test "subscriber receives :new_message after subscribe" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)
      {:ok, msg} = Messaging.send_message(channel.id, user.id, "subscribed")

      assert_receive {:new_message, ^msg}, 1000
    end

    test "unsubscribed process no longer receives messages" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)
      Messaging.unsubscribe_channel(channel.id)
      Messaging.send_message(channel.id, user.id, "invisible")

      refute_receive {:new_message, _}, 200
    end
  end

  describe "broadcast_typing/2" do
    test "delivers {:user_typing, user} to channel subscribers" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      Messaging.subscribe_channel(channel.id)
      Messaging.broadcast_typing(channel.id, user)

      assert_receive {:user_typing, ^user}, 1000
    end
  end

  describe "channel_count/0" do
    test "returns a non-negative integer" do
      assert Messaging.channel_count() >= 0
    end

    test "increments when a new ChannelServer starts" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      before = Messaging.channel_count()
      Messaging.send_message(channel.id, user.id, "start server")

      assert Messaging.channel_count() > before
    end
  end

  describe "ChannelSupervisor.ensure_started/2" do
    test "starts and returns a pid for a new target" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      assert {:ok, pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      assert is_pid(pid) and Process.alive?(pid)
    end

    test "returns the same pid when called twice for the same target" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      {:ok, pid1} = ChannelSupervisor.ensure_started({:channel, channel.id})
      {:ok, pid2} = ChannelSupervisor.ensure_started({:channel, channel.id})

      assert pid1 == pid2
    end

    test "registers the server in ChannelRegistry under the target key" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      {:ok, pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      [{^pid, _}] = Registry.lookup(Slackex.Messaging.ChannelRegistry, {:channel, channel.id})
    end

    test "via_tuple routes GenServer calls to the correct process" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      ChannelSupervisor.ensure_started({:channel, channel.id})

      assert {:ok, _msg} =
               ChannelServer.send_message(
                 ChannelServer.via_tuple(:channel, channel.id),
                 user.id,
                 "via tuple works"
               )
    end
  end
end
