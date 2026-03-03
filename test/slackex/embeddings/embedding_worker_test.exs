defmodule Slackex.Embeddings.EmbeddingWorkerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Embeddings.{EmbeddingWorker, MessageEmbedding}
  alias Slackex.Embeddings.EmbeddingClient

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp perform_batch(message_ids) do
    EmbeddingWorker.perform(%Oban.Job{args: %{"message_ids" => message_ids}})
  end

  # ---------------------------------------------------------------------------
  # Acceptance: batch embedding creates correct rows
  # ---------------------------------------------------------------------------

  describe "perform/1 with batch message_ids" do
    test "creates message_embeddings rows with correct message_id, embedding, and content_hash" do
      channel = insert(:channel)
      sender = insert(:user)
      msg1 = insert_channel_message(channel, sender, "Hello world")
      msg2 = insert_channel_message(channel, sender, "Goodbye world")

      assert :ok = perform_batch([msg1.id, msg2.id])

      emb1 = Repo.get(MessageEmbedding, msg1.id)
      emb2 = Repo.get(MessageEmbedding, msg2.id)

      assert emb1 != nil
      assert emb2 != nil

      # Verify content hashes are SHA-256 of the search_content
      assert emb1.content_hash == compute_content_hash("Hello world")
      assert emb2.content_hash == compute_content_hash("Goodbye world")

      # Verify embeddings are present and have correct dimensions
      # Pgvector wraps the list; convert to list for length check
      assert emb1.embedding |> Pgvector.to_list() |> length() == EmbeddingClient.dimensions()
      assert emb2.embedding |> Pgvector.to_list() |> length() == EmbeddingClient.dimensions()

      # Verify channel_id is populated
      assert emb1.channel_id == channel.id
      assert emb2.channel_id == channel.id
    end

    test "populates dm_conversation_id for DM messages" do
      dm = insert(:dm_conversation)
      sender = Repo.get!(Slackex.Accounts.User, dm.user_a_id)
      msg = insert_dm_message(dm, sender, "DM content")

      assert :ok = perform_batch([msg.id])

      emb = Repo.get!(MessageEmbedding, msg.id)
      assert emb.dm_conversation_id == dm.id
      assert emb.channel_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: content_hash dedup skips already-embedded messages
  # ---------------------------------------------------------------------------

  describe "content_hash deduplication" do
    test "skips messages whose content_hash already matches an existing embedding" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Same content")

      # First run creates the embedding
      assert :ok = perform_batch([msg.id])
      emb1 = Repo.get!(MessageEmbedding, msg.id)

      # Second run with same content should skip (no error, same row)
      assert :ok = perform_batch([msg.id])
      emb2 = Repo.get!(MessageEmbedding, msg.id)

      # Row unchanged (same inserted_at timestamp proves no re-insert)
      assert emb1.inserted_at == emb2.inserted_at
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: deleted messages are skipped
  # ---------------------------------------------------------------------------

  describe "deleted message handling" do
    test "skips messages with deleted_at set without error" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Will be deleted")

      # Soft-delete the message
      msg
      |> Slackex.Chat.Message.delete_changeset()
      |> Repo.update!()

      assert :ok = perform_batch([msg.id])

      # No embedding created for deleted message
      assert Repo.get(MessageEmbedding, msg.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # D4: Error handling -- worker handles EmbeddingClient errors gracefully
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns :ok and creates no embeddings when EmbeddingClient returns error" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Will fail to embed")

      # Swap the embedding client to a failing implementation
      original_client = Application.get_env(:slackex, :embedding_client)
      Application.put_env(:slackex, :embedding_client, Slackex.Embeddings.FailingClient)

      try do
        # The worker should handle the error gracefully without crashing
        assert :ok = perform_batch([msg.id])

        # No embedding should be created since the client returned an error
        assert Repo.get(MessageEmbedding, msg.id) == nil
      after
        Application.put_env(:slackex, :embedding_client, original_client)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: enqueue/1 chunks into batches of 50
  # ---------------------------------------------------------------------------

  describe "enqueue/1" do
    test "chunks 120 message IDs into 3 separate Oban jobs (50, 50, 20)" do
      message_ids = Enum.to_list(1..120)

      assert {:ok, jobs} = EmbeddingWorker.enqueue(message_ids)

      assert length(jobs) == 3

      [job1, job2, job3] = jobs
      assert length(job1.args["message_ids"]) == 50
      assert length(job2.args["message_ids"]) == 50
      assert length(job3.args["message_ids"]) == 20
    end

    test "sets priority 3 on enqueued jobs" do
      message_ids = Enum.to_list(1..10)

      assert {:ok, [job]} = EmbeddingWorker.enqueue(message_ids)
      assert job.priority == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: enqueue_backfill/1 uniqueness
  # ---------------------------------------------------------------------------

  describe "enqueue_backfill/1" do
    test "creates a backfill job for a channel" do
      channel = insert(:channel)

      assert {:ok, job} = EmbeddingWorker.enqueue_backfill(channel_id: channel.id)
      assert job.args["channel_id"] == channel.id
      assert job.args["backfill"] == true
    end

    test "second call within 1 hour for same channel returns existing job (uniqueness)" do
      channel = insert(:channel)

      assert {:ok, job1} = EmbeddingWorker.enqueue_backfill(channel_id: channel.id)
      assert {:ok, job2} = EmbeddingWorker.enqueue_backfill(channel_id: channel.id)

      # Same job ID means uniqueness constraint prevented duplicate
      assert job1.id == job2.id
    end
  end
end
