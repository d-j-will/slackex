defmodule Slackex.Pipeline.BatchWriterTest do
  # async: false because WriteSupervisor uses a registered name and the
  # async Task spawned in async_insert_batch needs a shared DB sandbox.
  use Slackex.DataCase, async: false

  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Pipeline.BatchWriter
  alias Slackex.Repo

  # Build a valid message map for a channel target using a real Snowflake ID
  # so BatchWriter can derive inserted_at correctly.
  defp channel_msg(user_id, channel_id) do
    %{
      id: Snowflake.generate(),
      content: "hello from batch",
      sender_id: user_id,
      channel_id: channel_id
    }
  end

  defp dm_msg(user_id, dm_id) do
    %{
      id: Snowflake.generate(),
      content: "hello from dm batch",
      sender_id: user_id,
      dm_conversation_id: dm_id
    }
  end

  describe "insert_batch/1" do
    test "inserts channel messages and returns count" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "batch-ch-#{System.unique_integer()}"})

      messages = [channel_msg(user.id, channel.id), channel_msg(user.id, channel.id)]

      assert {:ok, 2} = BatchWriter.insert_batch(messages)
    end

    test "inserts dm messages and returns count" do
      dm = insert(:dm_conversation)
      user = dm.user_a

      messages = [dm_msg(user.id, dm.id)]

      assert {:ok, 1} = BatchWriter.insert_batch(messages)
    end

    test "returns {:ok, 0} for empty list" do
      assert {:ok, 0} = BatchWriter.insert_batch([])
    end

    test "silently skips duplicate IDs (on_conflict: :nothing)" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "dedup-#{System.unique_integer()}"})

      msg = channel_msg(user.id, channel.id)

      assert {:ok, 1} = BatchWriter.insert_batch([msg])
      # Second insert with same ID is a no-op
      assert {:ok, 0} = BatchWriter.insert_batch([msg])
    end

    test "derives inserted_at from Snowflake ID" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "ts-ch-#{System.unique_integer()}"})

      before_ms = :os.system_time(:millisecond)
      msg = channel_msg(user.id, channel.id)
      after_ms = :os.system_time(:millisecond)

      {:ok, 1} = BatchWriter.insert_batch([msg])

      row = Repo.get!(Slackex.Chat.Message, msg.id)
      inserted_ms = DateTime.to_unix(row.inserted_at, :millisecond)

      assert inserted_ms >= before_ms
      assert inserted_ms <= after_ms
    end

    test "inserts multiple messages in a single batch" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "multi-#{System.unique_integer()}"})

      messages = for _ <- 1..10, do: channel_msg(user.id, channel.id)

      assert {:ok, 10} = BatchWriter.insert_batch(messages)
    end
  end

  describe "async_insert_batch/2" do
    # Slackex.WriteSupervisor is started by the application supervisor.
    test "sends {:batch_result, ref, :ok} to caller on success" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "async-ch-#{System.unique_integer()}"})

      msg = channel_msg(user.id, channel.id)
      ref = make_ref()

      BatchWriter.async_insert_batch([msg], ref)

      assert_receive {:batch_result, ^ref, :ok}, 2000
    end

    test "sends {:batch_result, ref, :ok} for empty batch" do
      ref = make_ref()
      BatchWriter.async_insert_batch([], ref)
      assert_receive {:batch_result, ^ref, :ok}, 2000
    end

    test "caller_ref is threaded through to the response" do
      user = insert(:user)

      {:ok, channel} =
        Slackex.Chat.create_channel(user.id, %{name: "ref-ch-#{System.unique_integer()}"})

      ref1 = make_ref()
      ref2 = make_ref()

      BatchWriter.async_insert_batch([channel_msg(user.id, channel.id)], ref1)
      BatchWriter.async_insert_batch([channel_msg(user.id, channel.id)], ref2)

      assert_receive {:batch_result, ^ref1, :ok}, 2000
      assert_receive {:batch_result, ^ref2, :ok}, 2000
    end
  end
end
