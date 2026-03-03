defmodule Slackex.Repo.Migrations.CreateMessageEmbeddings do
  use Ecto.Migration

  def up do
    create table(:message_embeddings, primary_key: false) do
      add :message_id, :bigint, primary_key: true
      add :message_inserted_at, :timestamptz, null: false
      add :channel_id, :bigint
      add :dm_conversation_id, :bigint
      add :embedding, :"vector(1536)"
      add :content_hash, :string, size: 64

      add :inserted_at, :timestamptz, null: false
    end

    create index(:message_embeddings, [:channel_id])
    create index(:message_embeddings, [:dm_conversation_id])

    execute """
    CREATE INDEX idx_embeddings_hnsw
      ON message_embeddings USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    drop table(:message_embeddings)
  end
end
