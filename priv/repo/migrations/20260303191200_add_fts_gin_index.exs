defmodule Slackex.Repo.Migrations.AddFtsGinIndex do
  @moduledoc """
  Adds a plaintext `search_content` column to messages for full-text search
  and creates a GIN index on `to_tsvector('english', search_content)`.

  The encrypted_content column stores AES-GCM ciphertext which cannot be
  indexed by PostgreSQL. This companion column holds plaintext specifically
  for FTS queries. New messages populate both columns via the changeset.

  Uses CREATE INDEX CONCURRENTLY for deploy safety (no table lock).
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TABLE messages ADD COLUMN IF NOT EXISTS search_content text"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_search_content_fts_idx
    ON messages USING GIN (to_tsvector('english', coalesce(search_content, '')))
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_search_content_fts_idx"

    alter table(:messages) do
      remove :search_content
    end
  end
end
