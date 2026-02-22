defmodule SlackexWeb.PresenceTest do
  # async: false — uses global Presence process and PubSub
  use Slackex.DataCase, async: false

  alias Slackex.Messaging
  alias SlackexWeb.Presence

  describe "SlackexWeb.Presence" do
    test "is running as part of the application supervision tree" do
      pid = Process.whereis(SlackexWeb.Presence)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "tracks a user on a channel presence topic" do
      user = insert(:user)
      channel_id = System.unique_integer([:positive])
      topic = "channel_presence:#{channel_id}"
      key = to_string(user.id)
      meta = %{username: user.username, joined_at: DateTime.utc_now()}

      {:ok, _ref} = Presence.track(self(), topic, key, meta)

      presences = Presence.list(topic)
      assert Map.has_key?(presences, key)
      assert hd(presences[key].metas).username == user.username
    end

    test "lists empty map for a topic with no tracked users" do
      topic = "channel_presence:#{System.unique_integer([:positive])}"
      assert Presence.list(topic) == %{}
    end

    test "broadcasts presence_diff to PubSub subscribers when a user joins" do
      channel_id = System.unique_integer([:positive])
      topic = "channel_presence:#{channel_id}"
      Phoenix.PubSub.subscribe(Slackex.PubSub, topic)

      user = insert(:user)
      key = to_string(user.id)

      {:ok, _ref} =
        Presence.track(self(), topic, key, %{
          username: user.username,
          joined_at: DateTime.utc_now()
        })

      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", topic: ^topic}, 1_000
    end

    test "presence_diff join payload includes tracked user key" do
      channel_id = System.unique_integer([:positive])
      topic = "channel_presence:#{channel_id}"
      Phoenix.PubSub.subscribe(Slackex.PubSub, topic)

      user = insert(:user)
      key = to_string(user.id)

      {:ok, _ref} =
        Presence.track(self(), topic, key, %{
          username: user.username,
          joined_at: DateTime.utc_now()
        })

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "presence_diff",
                       payload: %{joins: joins}
                     },
                     1_000

      assert Map.has_key?(joins, key)
    end
  end

  describe "Messaging.broadcast_typing/2" do
    test "delivers {:user_typing, user} to channel subscribers" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "t-#{System.unique_integer()}"})

      Messaging.subscribe_channel(channel.id)
      :ok = Messaging.broadcast_typing(channel.id, user)

      assert_receive {:user_typing, ^user}, 1_000
    end

    test "does not deliver typing events to unsubscribed processes" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "t-#{System.unique_integer()}"})

      :ok = Messaging.broadcast_typing(channel.id, user)

      refute_receive {:user_typing, _}, 200
    end

    test "multiple subscribers all receive typing event" do
      user = insert(:user)
      parent = self()

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "t-#{System.unique_integer()}"})

      Messaging.subscribe_channel(channel.id)

      task =
        Task.async(fn ->
          Messaging.subscribe_channel(channel.id)
          send(parent, :subscribed)

          receive do
            {:user_typing, _} -> :received
          after
            2_000 -> :timeout
          end
        end)

      assert_receive :subscribed, 1_000
      :ok = Messaging.broadcast_typing(channel.id, user)

      assert_receive {:user_typing, ^user}, 1_000
      assert Task.await(task, 2_000) == :received
    end
  end
end
