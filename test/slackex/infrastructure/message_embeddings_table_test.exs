defmodule Slackex.Infrastructure.MessageEmbeddingsTableTest do
  use Slackex.DataCase, async: true

  @moduledoc """
  Verifies that the message_embeddings table exists with the correct
  schema, HNSW index for cosine similarity, and btree indexes on
  channel_id and dm_conversation_id.
  """

  describe "message_embeddings table" do
    test "table exists with correct columns and types" do
      result =
        Repo.query!("""
        SELECT column_name, data_type, is_nullable, character_maximum_length
        FROM information_schema.columns
        WHERE table_name = 'message_embeddings'
        ORDER BY ordinal_position
        """)

      columns =
        for [name, type, nullable, max_length] <- result.rows, into: %{} do
          {name, %{type: type, nullable: nullable, max_length: max_length}}
        end

      assert map_size(columns) == 7

      assert columns["message_id"].type == "bigint"
      assert columns["message_id"].nullable == "NO"

      assert columns["message_inserted_at"].type == "timestamp with time zone"
      assert columns["message_inserted_at"].nullable == "NO"

      assert columns["channel_id"].type == "bigint"
      assert columns["channel_id"].nullable == "YES"

      assert columns["dm_conversation_id"].type == "bigint"
      assert columns["dm_conversation_id"].nullable == "YES"

      assert columns["embedding"].type == "USER-DEFINED"
      assert columns["embedding"].nullable == "YES"

      assert columns["content_hash"].type == "character varying"
      assert columns["content_hash"].nullable == "YES"
      assert columns["content_hash"].max_length == 64

      assert columns["inserted_at"].type == "timestamp with time zone"
      assert columns["inserted_at"].nullable == "NO"
    end

    test "message_id is the primary key" do
      result =
        Repo.query!("""
        SELECT kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
        WHERE tc.table_name = 'message_embeddings'
          AND tc.constraint_type = 'PRIMARY KEY'
        """)

      assert result.rows == [["message_id"]]
    end
  end

  describe "message_embeddings indexes" do
    test "HNSW index exists on embedding column with cosine distance" do
      result =
        Repo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'message_embeddings'
          AND indexname = 'idx_embeddings_hnsw'
        """)

      assert length(result.rows) == 1
      [[_name, indexdef]] = result.rows
      assert indexdef =~ "USING hnsw"
      assert indexdef =~ "vector_cosine_ops"
    end

    test "HNSW index has correct parameters (m=16, ef_construction=64)" do
      result =
        Repo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'message_embeddings'
          AND indexname = 'idx_embeddings_hnsw'
        """)

      assert length(result.rows) == 1
      [[_name, indexdef]] = result.rows
      assert indexdef =~ "m='16'"
      assert indexdef =~ "ef_construction='64'"
    end

    test "btree index exists on channel_id" do
      result =
        Repo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'message_embeddings'
          AND indexname = 'message_embeddings_channel_id_index'
        """)

      assert length(result.rows) == 1
      [[_name, indexdef]] = result.rows
      assert indexdef =~ "btree"
    end

    test "btree index exists on dm_conversation_id" do
      result =
        Repo.query!("""
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE tablename = 'message_embeddings'
          AND indexname = 'message_embeddings_dm_conversation_id_index'
        """)

      assert length(result.rows) == 1
      [[_name, indexdef]] = result.rows
      assert indexdef =~ "btree"
    end
  end
end
