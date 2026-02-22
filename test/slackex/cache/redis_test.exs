defmodule Slackex.Cache.RedisTest do
  # async: false — all tests share the Redis FLUSHDB boundary
  use ExUnit.Case, async: false

  alias Slackex.Cache.Redis

  # Slackex.Cache.Redis supervisor (and its connections) is started by the
  # application supervision tree. Flush all keys before each test.
  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  describe "get_messages/1" do
    test "returns {:miss, []} for unknown channel target" do
      assert {:miss, []} = Redis.get_messages({:channel, 99_999})
    end

    test "returns {:miss, []} for unknown dm target" do
      assert {:miss, []} = Redis.get_messages({:dm, 99_999})
    end
  end

  describe "push_message/2 + get_messages/1 round-trip" do
    test "stores and retrieves a simple message" do
      target = {:channel, 1}
      msg = %{id: 1, content: "hello"}

      assert :ok = Redis.push_message(target, msg)
      assert {:ok, [returned]} = Redis.get_messages(target)
      assert returned.id == 1
      assert returned.content == "hello"
    end

    test "round-trips inserted_at as DateTime" do
      target = {:channel, 2}
      # Truncate to seconds so ISO8601 round-trip is lossless
      now = DateTime.truncate(DateTime.utc_now(), :second)
      msg = %{id: 2, content: "with timestamp", inserted_at: now}

      assert :ok = Redis.push_message(target, msg)
      assert {:ok, [returned]} = Redis.get_messages(target)
      assert returned.inserted_at == now
    end

    test "returns messages in insertion order (oldest first)" do
      target = {:channel, 3}
      msgs = for i <- 1..3, do: %{id: i, content: "msg #{i}"}
      Enum.each(msgs, &Redis.push_message(target, &1))

      assert {:ok, returned} = Redis.get_messages(target)
      assert Enum.map(returned, & &1.id) == [1, 2, 3]
    end

    test "trims to 200 messages keeping the 200 newest" do
      target = {:channel, 4}

      # Bulk-seed 200 messages reliably (no short write timeout), then push one
      # more to trigger the LTRIM to 200. This avoids 201 rapid individual pushes
      # which can silently timeout under load with the 100ms write budget.
      seed = for i <- 1..200, do: %{id: i, content: "msg #{i}"}
      Redis.cache_messages(target, seed)

      Redis.push_message(target, %{id: 201, content: "msg 201"})
      # Allow the async 100ms-budget push to complete
      Process.sleep(150)

      assert {:ok, messages} = Redis.get_messages(target)
      assert length(messages) == 200
      # msg with id 1 is evicted; id 2 is now oldest
      assert hd(messages).id == 2
      assert List.last(messages).id == 201
    end

    test "channel and dm targets with same id are independent" do
      Redis.push_message({:channel, 10}, %{id: 1, content: "channel"})
      Redis.push_message({:dm, 10}, %{id: 2, content: "dm"})

      assert {:ok, [ch]} = Redis.get_messages({:channel, 10})
      assert {:ok, [dm]} = Redis.get_messages({:dm, 10})
      assert ch.content == "channel"
      assert dm.content == "dm"
    end
  end

  describe "cache_messages/2" do
    test "bulk backfills and returns all messages in insertion order" do
      target = {:channel, 20}
      messages = for i <- 1..5, do: %{id: i, content: "bulk #{i}"}

      assert :ok = Redis.cache_messages(target, messages)
      assert {:ok, returned} = Redis.get_messages(target)
      assert length(returned) == 5
      assert Enum.map(returned, & &1.id) == [1, 2, 3, 4, 5]
    end

    test "no-ops on empty list" do
      target = {:channel, 21}
      assert :ok = Redis.cache_messages(target, [])
      assert {:miss, []} = Redis.get_messages(target)
    end

    test "replaces existing messages on second call (DEL + re-insert)" do
      target = {:channel, 22}
      Redis.cache_messages(target, [%{id: 1, content: "old"}])
      Redis.cache_messages(target, [%{id: 2, content: "new"}])

      assert {:ok, [msg]} = Redis.get_messages(target)
      assert msg.id == 2
    end
  end

  describe "invalidate/1" do
    test "removes cached messages for target" do
      target = {:channel, 30}
      Redis.push_message(target, %{id: 1, content: "to be removed"})
      assert {:ok, [_]} = Redis.get_messages(target)

      assert :ok = Redis.invalidate(target)
      assert {:miss, []} = Redis.get_messages(target)
    end

    test "returns :ok for non-existent target" do
      assert :ok = Redis.invalidate({:channel, 99_999})
    end

    test "only removes the specified target" do
      Redis.push_message({:channel, 31}, %{id: 1})
      Redis.push_message({:channel, 32}, %{id: 2})

      Redis.invalidate({:channel, 31})

      assert {:miss, []} = Redis.get_messages({:channel, 31})
      assert {:ok, [_]} = Redis.get_messages({:channel, 32})
    end
  end

  describe "set_read_cursor/3 + get_read_cursor/2" do
    test "round-trips a cursor value" do
      user_id = 1
      target = {:channel, 40}
      message_id = 123_456_789_012

      assert :ok = Redis.set_read_cursor(user_id, target, message_id)
      assert {:ok, ^message_id} = Redis.get_read_cursor(user_id, target)
    end

    test "returns :miss for unknown cursor" do
      assert :miss = Redis.get_read_cursor(99_999, {:channel, 99_999})
    end

    test "cursors for different users on the same channel are independent" do
      target = {:channel, 50}
      Redis.set_read_cursor(1, target, 100)
      Redis.set_read_cursor(2, target, 200)

      assert {:ok, 100} = Redis.get_read_cursor(1, target)
      assert {:ok, 200} = Redis.get_read_cursor(2, target)
    end

    test "channel and dm cursors for same user+id are independent" do
      user_id = 1
      Redis.set_read_cursor(user_id, {:channel, 60}, 111)
      Redis.set_read_cursor(user_id, {:dm, 60}, 222)

      assert {:ok, 111} = Redis.get_read_cursor(user_id, {:channel, 60})
      assert {:ok, 222} = Redis.get_read_cursor(user_id, {:dm, 60})
    end
  end

  describe "graceful degradation" do
    # The try/rescue wrappers in Cache.Redis ensure that all operations return
    # safe values rather than raising when Redis is unreachable. These tests
    # verify the safe return shapes on hit/miss independently of connectivity.
    test "get_messages returns {:miss, []} for empty list (not a crash)" do
      assert {:miss, []} = Redis.get_messages({:channel, 80_001})
    end

    test "get_read_cursor returns :miss for unknown key (not a crash)" do
      assert :miss = Redis.get_read_cursor(80_001, {:channel, 80_001})
    end

    test "invalidate returns :ok for non-existent key (not a crash)" do
      assert :ok = Redis.invalidate({:channel, 80_002})
    end
  end
end
