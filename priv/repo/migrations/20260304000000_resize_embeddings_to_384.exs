defmodule Slackex.Repo.Migrations.ResizeEmbeddingsTo384 do
  use Ecto.Migration

  def up do
    execute "DROP INDEX IF EXISTS idx_embeddings_hnsw"

    alter table(:message_embeddings) do
      modify :embedding, :"vector(384)"
    end

    execute """
    CREATE INDEX idx_embeddings_hnsw
      ON message_embeddings USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_embeddings_hnsw"

    alter table(:message_embeddings) do
      modify :embedding, :"vector(1536)"
    end

    execute """
    CREATE INDEX idx_embeddings_hnsw
      ON message_embeddings USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    """
  end
end
