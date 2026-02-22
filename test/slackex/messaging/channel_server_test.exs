defmodule Slackex.Messaging.ChannelServerTest do
  # async: false — tests share the global ChannelRegistry and ChannelSupervisor
  use Slackex.DataCase, async: false

  alias Slackex.Messaging.ChannelServer
  alias Slackex.Messaging.ChannelSupervisor

  # Start a fresh ChannelServer backed by a unique channel for each test.
  # The channel creator gets the "owner" role and can send messages.
  setup do
    user = insert(:user)

    {:ok, channel} =
      Slackex.Chat.create_channel(user.id, %{name: "srv-#{System.unique_integer()}"})

    {:ok, pid} = ChannelSupervisor.ensure_started({:channel, channel.id})
    server = ChannelServer.via_tuple(:channel, channel.id)

    on_exit(fn ->
      if Process.alive?(pid), do: Horde.DynamicSupervisor.terminate_child(ChannelSupervisor, pid)
    end)

    %{user: user, channel: channel, server: server}
  end

  describe "send_message/3" do
    test "returns {:ok, message} with all expected fields for authorized user",
         %{user: user, channel: channel, server: server} do
      assert {:ok, msg} = ChannelServer.send_message(server, user.id, "hello world")

      assert is_integer(msg.id) and msg.id > 0
      assert msg.content == "hello world"
      assert msg.sender_id == user.id
      assert msg.channel_id == channel.id
      assert %DateTime{} = msg.inserted_at
    end

    test "message timestamp is derived from Snowflake ID", %{user: user, server: server} do
      before_ms = :os.system_time(:millisecond)
      {:ok, msg} = ChannelServer.send_message(server, user.id, "ts test")
      after_ms = :os.system_time(:millisecond)

      ts_ms = DateTime.to_unix(msg.inserted_at, :millisecond)
      assert ts_ms >= before_ms
      assert ts_ms <= after_ms
    end

    test "returns {:error, :unauthorized} for a user with no role", %{channel: channel} do
      outsider = insert(:user)
      server = ChannelServer.via_tuple(:channel, channel.id)
      assert {:error, :unauthorized} = ChannelServer.send_message(server, outsider.id, "intruder")
    end

    test "returns {:error, :rate_limited} after exhausting 10-message/s bucket",
         %{user: user, server: server} do
      # Consume all 10 tokens in rapid succession (sub-millisecond each)
      for _ <- 1..10, do: ChannelServer.send_message(server, user.id, "burst")

      assert {:error, :rate_limited} = ChannelServer.send_message(server, user.id, "11th")
    end

    test "each user has an independent rate limiter bucket",
         %{user: owner, channel: channel, server: server} do
      member = insert(:user)
      Slackex.Chat.join_channel(member.id, channel.id)

      # Exhaust owner's rate limit bucket
      for _ <- 1..10, do: ChannelServer.send_message(server, owner.id, "burst")
      assert {:error, :rate_limited} = ChannelServer.send_message(server, owner.id, "over")

      # Member's bucket is completely independent — should succeed
      assert {:ok, _msg} = ChannelServer.send_message(server, member.id, "member ok")
    end

    test "broadcasts {:envelope, envelope} with message.new event to PubSub channel topic",
         %{user: user, channel: channel, server: server} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel.id}")
      {:ok, msg} = ChannelServer.send_message(server, user.id, "broadcast me")

      assert_receive {:envelope, envelope}, 1000
      assert envelope.v == 1
      assert envelope.event == "message.new"
      assert envelope.target == %{type: :channel, id: channel.id}
      assert envelope.payload == msg
    end

    test "returns {:error, :backpressure} when pending_writes is full",
         %{user: user, server: server} do
      pid = GenServer.whereis(server)

      :sys.replace_state(pid, fn state ->
        %{state | pending_writes: List.duplicate(%{}, 1_000)}
      end)

      assert {:error, :backpressure} = ChannelServer.send_message(server, user.id, "overflow")
    end

    test "returns {:error, :invalid_content} for empty content",
         %{user: user, server: server} do
      assert {:error, :invalid_content} = ChannelServer.send_message(server, user.id, "")
    end

    test "returns {:error, :invalid_content} for whitespace-only content",
         %{user: user, server: server} do
      assert {:error, :invalid_content} = ChannelServer.send_message(server, user.id, "   ")
    end

    test "returns {:error, :invalid_content} for content exceeding 4000 chars",
         %{user: user, server: server} do
      long = String.duplicate("a", 4_001)
      assert {:error, :invalid_content} = ChannelServer.send_message(server, user.id, long)
    end

    test "consecutive messages produce strictly increasing IDs",
         %{user: user, server: server} do
      {:ok, m1} = ChannelServer.send_message(server, user.id, "first")
      {:ok, m2} = ChannelServer.send_message(server, user.id, "second")

      assert m2.id > m1.id
    end
  end

  describe "get_recent_messages/2" do
    test "returns empty list before any messages are sent", %{server: server} do
      assert [] = ChannelServer.get_recent_messages(server, 50)
    end

    test "returns messages in chronological order (oldest first)",
         %{user: user, server: server} do
      {:ok, m1} = ChannelServer.send_message(server, user.id, "first")
      {:ok, m2} = ChannelServer.send_message(server, user.id, "second")
      {:ok, m3} = ChannelServer.send_message(server, user.id, "third")

      messages = ChannelServer.get_recent_messages(server, 50)
      ids = Enum.map(messages, & &1.id)

      # Snowflake IDs are monotonically increasing — sorted order == insertion order
      assert ids == Enum.sort(ids)
      assert ids == Enum.map([m1, m2, m3], & &1.id)
    end

    test "respects the limit parameter", %{user: user, server: server} do
      for i <- 1..5, do: ChannelServer.send_message(server, user.id, "msg #{i}")

      assert length(ChannelServer.get_recent_messages(server, 3)) == 3
    end

    test "queue is bounded at 200 entries",
         %{channel: channel, server: server} do
      # Each user is rate-limited to 10 msg/s; 21 users × 10 msgs = 210 total,
      # exceeding the 200-entry bound without hitting per-user rate limits.
      users =
        for _ <- 1..21 do
          u = insert(:user)
          Slackex.Chat.join_channel(u.id, channel.id)
          u
        end

      for u <- users, _ <- 1..10 do
        ChannelServer.send_message(server, u.id, "x")
      end

      assert length(ChannelServer.get_recent_messages(server, 300)) == 200
    end
  end
end
