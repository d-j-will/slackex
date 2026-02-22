defmodule Slackex.CacheTest do
  # async: false — tests share ETS table and Redis FLUSHDB
  use ExUnit.Case, async: false

  alias Slackex.Cache
  alias Slackex.Cache.Local
  alias Slackex.Cache.Redis

  setup do
    :ets.delete_all_objects(:slackex_message_cache)
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  describe "get_messages/1 — three-tier cascade" do
    test "returns {:miss, []} when both ETS and Redis are empty" do
      assert {:miss, []} = Cache.get_messages({:channel, 1})
    end

    test "ETS hit returns without touching Redis" do
      target = {:channel, 2}
      msg = %{id: 1, content: "ets only"}

      # Put directly into ETS only (bypass Redis)
      Local.put_message(target, msg)

      assert {:ok, [^msg]} = Cache.get_messages(target)

      # Redis should remain empty for this target
      assert {:miss, []} = Redis.get_messages(target)
    end

    test "Redis hit backfills ETS and returns messages" do
      target = {:channel, 3}
      msg = %{id: 2, content: "redis only"}

      # Put directly into Redis only (bypass ETS)
      Redis.push_message(target, msg)

      # ETS starts empty
      assert {:ok, []} = Local.get_messages(target)

      # Cache reads from Redis
      assert {:ok, [returned]} = Cache.get_messages(target)
      assert returned.id == 2

      # ETS is now backfilled
      assert {:ok, [backfilled]} = Local.get_messages(target)
      assert backfilled.id == 2
    end

    test "returns {:miss, []} when Redis also misses" do
      assert {:miss, []} = Cache.get_messages({:channel, 9_999})
    end
  end

  describe "put_message/2" do
    test "writes through to both ETS and Redis" do
      target = {:channel, 10}
      msg = %{id: 100, content: "write-through"}

      assert :ok = Cache.put_message(target, msg)

      # ETS
      assert {:ok, [^msg]} = Local.get_messages(target)

      # Redis
      assert {:ok, [redis_msg]} = Redis.get_messages(target)
      assert redis_msg.id == 100
      assert redis_msg.content == "write-through"
    end

    test "successive writes are visible in both layers" do
      target = {:channel, 11}
      msg1 = %{id: 1, content: "first"}
      msg2 = %{id: 2, content: "second"}

      Cache.put_message(target, msg1)
      Cache.put_message(target, msg2)

      assert {:ok, ets_msgs} = Local.get_messages(target)
      assert length(ets_msgs) == 2

      assert {:ok, redis_msgs} = Redis.get_messages(target)
      assert length(redis_msgs) == 2
    end
  end

  describe "invalidate/1" do
    test "clears both ETS and Redis" do
      target = {:channel, 20}
      msg = %{id: 200, content: "to invalidate"}

      Cache.put_message(target, msg)
      assert {:ok, [_]} = Local.get_messages(target)
      assert {:ok, [_]} = Redis.get_messages(target)

      assert :ok = Cache.invalidate(target)

      assert {:ok, []} = Local.get_messages(target)
      assert {:miss, []} = Redis.get_messages(target)
    end

    test "returns :ok for non-existent target" do
      assert :ok = Cache.invalidate({:channel, 99_999})
    end
  end

  describe "cache_messages/2" do
    test "backfills both ETS and Redis with all messages" do
      target = {:channel, 30}
      messages = for i <- 1..3, do: %{id: i, content: "bulk #{i}"}

      assert :ok = Cache.cache_messages(target, messages)

      assert {:ok, ets_msgs} = Local.get_messages(target)
      assert length(ets_msgs) == 3

      assert {:ok, redis_msgs} = Redis.get_messages(target)
      assert length(redis_msgs) == 3
    end

    test "subsequent get_messages returns ETS hit (no Redis call needed)" do
      target = {:channel, 31}
      messages = for i <- 1..2, do: %{id: i, content: "msg #{i}"}

      Cache.cache_messages(target, messages)

      # ETS is populated, so next get should hit ETS directly
      assert {:ok, result} = Cache.get_messages(target)
      assert length(result) == 2

      # ETS still has data (wasn't cleared by the read)
      assert {:ok, [_ | _]} = Local.get_messages(target)
    end

    test "no-ops on empty list" do
      target = {:channel, 32}
      assert :ok = Cache.cache_messages(target, [])
      assert {:miss, []} = Cache.get_messages(target)
    end
  end
end
