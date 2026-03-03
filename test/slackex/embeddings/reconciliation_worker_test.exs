defmodule Slackex.Embeddings.ReconciliationWorkerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Embeddings.{ReconciliationWorker, MessageEmbedding}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_embedding_for(message) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = compute_content_hash(message.search_content)
    vector = List.duplicate(0.1, Slackex.Embeddings.EmbeddingClient.dimensions())

    %MessageEmbedding{}
    |> MessageEmbedding.changeset(%{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: vector,
      content_hash: hash,
      inserted_at: now
    })
    |> Repo.insert!()
  end

  defp perform_reconciliation do
    ReconciliationWorker.perform(%Oban.Job{args: %{}})
  end

  # ---------------------------------------------------------------------------
  # Acceptance: discovers unembedded messages from the last hour
  # ---------------------------------------------------------------------------

  describe "perform/1 reconciliation" do
    test "discovers unembedded messages from the last hour and enqueues them" do
      channel = insert(:channel)
      sender = insert(:user)
      msg1 = insert_channel_message(channel, sender, "Unembedded one")
      msg2 = insert_channel_message(channel, sender, "Unembedded two")

      # No embeddings exist for these messages
      assert Repo.get(MessageEmbedding, msg1.id) == nil
      assert Repo.get(MessageEmbedding, msg2.id) == nil

      # Run reconciliation — with Oban inline mode, the enqueued
      # EmbeddingWorker jobs execute synchronously
      assert :ok = perform_reconciliation()

      # Verify embeddings were created (proving workers were enqueued and ran)
      emb1 = Repo.get(MessageEmbedding, msg1.id)
      emb2 = Repo.get(MessageEmbedding, msg2.id)

      assert emb1 != nil, "Expected embedding for message #{msg1.id}"
      assert emb2 != nil, "Expected embedding for message #{msg2.id}"
    end

    test "does not enqueue jobs when all recent messages already have embeddings" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Already embedded")

      # Pre-create the embedding
      insert_embedding_for(msg)

      # Capture the existing embedding's inserted_at
      original_emb = Repo.get!(MessageEmbedding, msg.id)

      assert :ok = perform_reconciliation()

      # Embedding should be unchanged (no re-embedding occurred)
      current_emb = Repo.get!(MessageEmbedding, msg.id)
      assert original_emb.inserted_at == current_emb.inserted_at
    end

    test "ignores messages older than the lookback window" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Old message")

      # Backdate the message's inserted_at to 2 hours ago
      two_hours_ago =
        DateTime.utc_now()
        |> DateTime.add(-7200, :second)
        |> DateTime.truncate(:microsecond)

      from(m in Slackex.Chat.Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [inserted_at: two_hours_ago])

      assert :ok = perform_reconciliation()

      # Message outside lookback window should NOT get an embedding
      assert Repo.get(MessageEmbedding, msg.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # D6: Boundary conditions for lookback window (3600 seconds)
  # ---------------------------------------------------------------------------

  describe "lookback window boundary conditions" do
    test "message at 3599 seconds ago (inside window) is discovered and embedded" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Just inside window")

      # Backdate to 3599 seconds ago -- just inside the 3600s lookback
      just_inside =
        DateTime.utc_now()
        |> DateTime.add(-3599, :second)
        |> DateTime.truncate(:microsecond)

      from(m in Slackex.Chat.Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [inserted_at: just_inside])

      assert :ok = perform_reconciliation()

      # Should be embedded -- it's inside the lookback window
      assert Repo.get(MessageEmbedding, msg.id) != nil,
             "Expected message at 3599s ago to be embedded (inside 3600s window)"
    end

    test "message at 3601 seconds ago (outside window) is not discovered" do
      channel = insert(:channel)
      sender = insert(:user)
      msg = insert_channel_message(channel, sender, "Just outside window")

      # Backdate to 3601 seconds ago -- just outside the 3600s lookback
      just_outside =
        DateTime.utc_now()
        |> DateTime.add(-3601, :second)
        |> DateTime.truncate(:microsecond)

      from(m in Slackex.Chat.Message, where: m.id == ^msg.id)
      |> Repo.update_all(set: [inserted_at: just_outside])

      assert :ok = perform_reconciliation()

      # Should NOT be embedded -- it's outside the lookback window
      assert Repo.get(MessageEmbedding, msg.id) == nil,
             "Expected message at 3601s ago to NOT be embedded (outside 3600s window)"
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: batch chunking
  # ---------------------------------------------------------------------------

  describe "batch chunking" do
    test "processes more than 50 unembedded messages in batches of 50" do
      channel = insert(:channel)
      sender = insert(:user)

      # Create 75 messages without embeddings
      messages =
        for i <- 1..75 do
          insert_channel_message(channel, sender, "Batch message #{i}")
        end

      assert :ok = perform_reconciliation()

      # All 75 should have embeddings after reconciliation
      embedded_count =
        from(me in MessageEmbedding, where: me.message_id in ^Enum.map(messages, & &1.id))
        |> Repo.aggregate(:count)

      assert embedded_count == 75
    end
  end
end
