defmodule Slackex.MessagingTest do
  # async: false — shares the global ChannelRegistry and ChannelSupervisor
  use Slackex.DataCase, async: false

  alias Slackex.Messaging
  alias Slackex.Messaging.{ChannelServer, ChannelSupervisor}

  # Stop a ChannelServer by target tuple if one is running.
  defp stop_server(target) do
    case Horde.Registry.lookup(Slackex.Messaging.ChannelRegistry, target) do
      [{pid, _}] ->
        if Process.alive?(pid),
          do: Horde.DynamicSupervisor.terminate_child(ChannelSupervisor, pid)

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
    test "subscriber receives {:envelope, envelope} after subscribe" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)
      {:ok, msg} = Messaging.send_message(channel.id, user.id, "subscribed")

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.new"
      assert envelope.payload == msg
    end

    test "unsubscribed process no longer receives messages" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)
      Messaging.unsubscribe_channel(channel.id)
      Messaging.send_message(channel.id, user.id, "invisible")

      refute_receive {:envelope, _}, 200
    end
  end

  describe "subscribe_dm/1 and unsubscribe_dm/1" do
    test "subscriber receives messages after subscribe_dm" do
      dm = insert(:dm_conversation)
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      Messaging.subscribe_dm(dm.id)
      {:ok, msg} = Messaging.send_dm(dm.id, dm.user_a.id, "dm hello")

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.new"
      assert envelope.payload == msg
    end

    test "unsubscribed process no longer receives DM messages" do
      dm = insert(:dm_conversation)
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      Messaging.subscribe_dm(dm.id)
      Messaging.unsubscribe_dm(dm.id)
      Messaging.send_dm(dm.id, dm.user_a.id, "invisible dm")

      refute_receive {:envelope, _}, 200
    end
  end

  describe "broadcast_typing/2" do
    test "delivers {:envelope, envelope} with typing event to channel subscribers" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      Messaging.subscribe_channel(channel.id)
      Messaging.broadcast_typing(channel.id, user)

      assert_receive {:envelope, envelope}, 1000
      assert envelope.v == 1
      assert envelope.event == "typing"
      assert envelope.target == %{type: :channel, id: channel.id}
      assert envelope.payload == %{user_id: user.id, username: user.username}
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

  describe "edit_message/3" do
    test "delegates to Chat, broadcasts message.edited envelope on channel topic" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      # Persist message to DB via Chat context directly
      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "original")

      # Start ChannelServer (loads message from DB on init)
      {:ok, _pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)

      assert {:ok, edited} = Messaging.edit_message(db_msg.id, user.id, "updated")
      assert edited.content == "updated"
      assert edited.edited_at != nil

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.edited"
      assert envelope.payload.id == db_msg.id
      assert envelope.payload.content == "updated"
      assert envelope.payload.edited_at != nil
    end

    test "updates the ChannelServer in-memory queue on edit" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "before edit")

      {:ok, _pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      on_exit(fn -> stop_server({:channel, channel.id}) end)

      {:ok, _edited} = Messaging.edit_message(db_msg.id, user.id, "after edit")

      # Allow PubSub handle_info to process
      Process.sleep(100)

      messages = Messaging.get_recent_messages(channel.id, 50)
      edited_in_queue = Enum.find(messages, &(&1.id == db_msg.id))

      assert edited_in_queue.content == "after edit"
      assert edited_in_queue.edited_at != nil
    end

    test "broadcasts message.edited envelope on DM topic" do
      dm = insert(:dm_conversation)

      {:ok, db_msg} = Slackex.Chat.send_dm(dm.id, dm.user_a.id, "dm original")

      {:ok, _pid} = ChannelSupervisor.ensure_started({:dm, dm.id})
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      Messaging.subscribe_dm(dm.id)

      assert {:ok, edited} = Messaging.edit_message(db_msg.id, dm.user_a.id, "dm updated")
      assert edited.content == "dm updated"

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.edited"
      assert envelope.target == %{type: :dm, id: dm.id}
    end

    test "returns error when edit fails in Chat context" do
      user = insert(:user)
      other = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "mine")

      assert {:error, :unauthorized} = Messaging.edit_message(db_msg.id, other.id, "hijack")
    end
  end

  describe "delete_message/3" do
    test "delegates to Chat, broadcasts message.deleted envelope on channel topic" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "to delete")

      {:ok, _pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      on_exit(fn -> stop_server({:channel, channel.id}) end)

      Messaging.subscribe_channel(channel.id)

      assert {:ok, deleted} = Messaging.delete_message(db_msg.id, user.id)
      assert deleted.content == nil
      assert deleted.deleted_at != nil

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.deleted"
      assert envelope.payload.id == db_msg.id
      assert envelope.payload.deleted_at != nil
    end

    test "updates the ChannelServer in-memory queue on delete" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "will be deleted")

      {:ok, _pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
      on_exit(fn -> stop_server({:channel, channel.id}) end)

      {:ok, _deleted} = Messaging.delete_message(db_msg.id, user.id)

      # Allow PubSub handle_info to process
      Process.sleep(100)

      messages = Messaging.get_recent_messages(channel.id, 50)
      deleted_in_queue = Enum.find(messages, &(&1.id == db_msg.id))

      assert deleted_in_queue.content == nil
      assert deleted_in_queue.deleted_at != nil
    end

    test "broadcasts message.deleted envelope on DM topic" do
      dm = insert(:dm_conversation)

      {:ok, db_msg} = Slackex.Chat.send_dm(dm.id, dm.user_a.id, "dm to delete")

      {:ok, _pid} = ChannelSupervisor.ensure_started({:dm, dm.id})
      on_exit(fn -> stop_server({:dm, dm.id}) end)

      Messaging.subscribe_dm(dm.id)

      assert {:ok, _deleted} = Messaging.delete_message(db_msg.id, dm.user_a.id)

      assert_receive {:envelope, envelope}, 1000
      assert envelope.event == "message.deleted"
      assert envelope.target == %{type: :dm, id: dm.id}
    end

    test "returns error when delete fails in Chat context" do
      user = insert(:user)
      other = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "m-#{System.unique_integer()}"})

      {:ok, db_msg} = Slackex.Chat.send_message(channel.id, user.id, "mine")

      assert {:error, :unauthorized} = Messaging.delete_message(db_msg.id, other.id)
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

      [{^pid, _}] =
        Horde.Registry.lookup(Slackex.Messaging.ChannelRegistry, {:channel, channel.id})
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
