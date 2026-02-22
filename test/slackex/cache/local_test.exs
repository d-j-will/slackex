defmodule Slackex.Cache.LocalTest do
  use ExUnit.Case, async: false

  alias Slackex.Cache.Local

  # Cache.Local is started by the application supervisor.
  # Clear all ETS entries between tests to ensure isolation.
  setup do
    :ets.delete_all_objects(:slackex_message_cache)
    :ok
  end

  describe "get_messages/1" do
    test "returns empty list for unknown target" do
      assert {:ok, []} = Local.get_messages({:channel, 1})
    end

    test "returns empty list for unknown dm target" do
      assert {:ok, []} = Local.get_messages({:dm, 1})
    end
  end

  describe "put_message/2 and get_messages/1" do
    test "stores and retrieves a single message" do
      msg = %{id: 1, content: "hello"}
      assert :ok = Local.put_message({:channel, 1}, msg)
      assert {:ok, [^msg]} = Local.get_messages({:channel, 1})
    end

    test "returns messages in chronological order (oldest first)" do
      msg1 = %{id: 1, content: "first"}
      msg2 = %{id: 2, content: "second"}
      msg3 = %{id: 3, content: "third"}

      Local.put_message({:channel, 1}, msg1)
      Local.put_message({:channel, 1}, msg2)
      Local.put_message({:channel, 1}, msg3)

      assert {:ok, [^msg1, ^msg2, ^msg3]} = Local.get_messages({:channel, 1})
    end

    test "channel and dm targets with the same id are independent" do
      ch_msg = %{id: 1, content: "channel"}
      dm_msg = %{id: 2, content: "dm"}

      Local.put_message({:channel, 42}, ch_msg)
      Local.put_message({:dm, 42}, dm_msg)

      assert {:ok, [^ch_msg]} = Local.get_messages({:channel, 42})
      assert {:ok, [^dm_msg]} = Local.get_messages({:dm, 42})
    end

    test "different targets do not interfere with each other" do
      Local.put_message({:channel, 1}, %{id: 1})
      Local.put_message({:channel, 2}, %{id: 2})

      assert {:ok, [%{id: 1}]} = Local.get_messages({:channel, 1})
      assert {:ok, [%{id: 2}]} = Local.get_messages({:channel, 2})
    end

    test "trims to 200 messages, keeping the newest" do
      target = {:channel, 99}

      for i <- 1..205 do
        Local.put_message(target, %{id: i, content: "msg #{i}"})
      end

      {:ok, messages} = Local.get_messages(target)

      # Exactly 200 messages retained
      assert length(messages) == 200

      # Oldest retained message has id 6 (1..5 were evicted as newest-first
      # trimming drops from the tail)
      assert hd(messages).id == 6

      # Most recent message is last (chronological order)
      assert List.last(messages).id == 205
    end
  end

  describe "invalidate/1" do
    test "removes an existing target's cache entry" do
      Local.put_message({:channel, 1}, %{id: 1, content: "hello"})
      assert :ok = Local.invalidate({:channel, 1})
      assert {:ok, []} = Local.get_messages({:channel, 1})
    end

    test "returns :ok for a non-existent target" do
      assert :ok = Local.invalidate({:channel, 999})
    end

    test "only removes the specified target" do
      Local.put_message({:channel, 1}, %{id: 1})
      Local.put_message({:channel, 2}, %{id: 2})

      Local.invalidate({:channel, 1})

      assert {:ok, []} = Local.get_messages({:channel, 1})
      assert {:ok, [%{id: 2}]} = Local.get_messages({:channel, 2})
    end
  end

  describe "stats/0" do
    test "returns zero size for empty cache" do
      assert %{memory_bytes: bytes, size: 0} = Local.stats()
      assert bytes > 0
    end

    test "size reflects the number of distinct targets" do
      Local.put_message({:channel, 1}, %{id: 1})
      Local.put_message({:channel, 2}, %{id: 2})
      Local.put_message({:dm, 1}, %{id: 3})

      assert %{size: 3} = Local.stats()
    end

    test "size decreases after invalidation" do
      Local.put_message({:channel, 1}, %{id: 1})
      Local.put_message({:channel, 2}, %{id: 2})
      Local.invalidate({:channel, 1})

      assert %{size: 1} = Local.stats()
    end
  end

  describe "LRU eviction" do
    test "keeps table size at or below 1000 targets" do
      for i <- 1..1000 do
        Local.put_message({:channel, i}, %{id: i})
      end

      assert Local.stats().size == 1000

      # One more write triggers eviction — size must not exceed the limit
      Local.put_message({:channel, 1001}, %{id: 1001})

      assert Local.stats().size == 1000
    end

    test "newly written target is retained after eviction" do
      for i <- 1..1001 do
        Local.put_message({:channel, i}, %{id: i})
      end

      # The last-written target must survive eviction
      assert {:ok, [%{id: 1001}]} = Local.get_messages({:channel, 1001})
    end
  end
end
