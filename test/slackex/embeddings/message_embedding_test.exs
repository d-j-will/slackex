defmodule Slackex.Embeddings.MessageEmbeddingTest do
  @moduledoc """
  Acceptance tests for the MessageEmbedding Ecto schema.

  Verifies:
  - A 384-dimension vector can be inserted and read back with correct values
  - The Repo handles vector columns via custom Postgrex types
  - content_hash stores a 64-character SHA-256 hex string
  """

  use Slackex.DataCase, async: true

  alias Slackex.Embeddings.MessageEmbedding

  @vector_dimensions 384

  describe "roundtrip persistence of MessageEmbedding" do
    test "inserts and reads back a 384-dimension embedding vector with correct values" do
      # Generate a deterministic 384-dim vector
      vector = for i <- 1..@vector_dimensions, do: :math.sin(i / 100.0)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        message_id: 100_001,
        message_inserted_at: now,
        channel_id: 42,
        embedding: vector,
        content_hash: String.duplicate("a", 64),
        inserted_at: now
      }

      # Insert
      {:ok, inserted} =
        %MessageEmbedding{}
        |> MessageEmbedding.changeset(attrs)
        |> Repo.insert()

      assert inserted.message_id == 100_001

      # Read back
      loaded = Repo.get!(MessageEmbedding, 100_001)

      assert loaded.message_id == 100_001
      assert loaded.channel_id == 42
      assert loaded.dm_conversation_id == nil
      assert loaded.content_hash == String.duplicate("a", 64)
      assert loaded.message_inserted_at == now

      # Verify vector dimensions and values match
      loaded_vector = Pgvector.to_list(loaded.embedding)
      assert length(loaded_vector) == @vector_dimensions

      Enum.zip(vector, loaded_vector)
      |> Enum.each(fn {expected, actual} ->
        assert_in_delta expected, actual, 1.0e-6
      end)
    end

    test "inserts embedding for a DM conversation (no channel_id)" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      vector = for _ <- 1..@vector_dimensions, do: 0.0

      attrs = %{
        message_id: 100_002,
        message_inserted_at: now,
        dm_conversation_id: 99,
        embedding: vector,
        content_hash: String.duplicate("b", 64),
        inserted_at: now
      }

      {:ok, inserted} =
        %MessageEmbedding{}
        |> MessageEmbedding.changeset(attrs)
        |> Repo.insert()

      loaded = Repo.get!(MessageEmbedding, inserted.message_id)
      assert loaded.dm_conversation_id == 99
      assert loaded.channel_id == nil
    end
  end

  describe "content_hash validation" do
    test "stores a 64-character SHA-256 hex string" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      hash = :crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower)
      assert String.length(hash) == 64

      attrs = %{
        message_id: 100_003,
        message_inserted_at: now,
        channel_id: 1,
        embedding: for(_ <- 1..@vector_dimensions, do: 0.1),
        content_hash: hash,
        inserted_at: now
      }

      {:ok, _inserted} =
        %MessageEmbedding{}
        |> MessageEmbedding.changeset(attrs)
        |> Repo.insert()

      loaded = Repo.get!(MessageEmbedding, 100_003)
      assert loaded.content_hash == hash
      assert String.length(loaded.content_hash) == 64
    end
  end

  describe "schema configuration" do
    test "message_id is the primary key (not auto-generated)" do
      assert MessageEmbedding.__schema__(:primary_key) == [:message_id]
    end

    test "has expected fields" do
      fields = MessageEmbedding.__schema__(:fields)
      assert :message_id in fields
      assert :message_inserted_at in fields
      assert :channel_id in fields
      assert :dm_conversation_id in fields
      assert :embedding in fields
      assert :content_hash in fields
      assert :inserted_at in fields
    end
  end
end
