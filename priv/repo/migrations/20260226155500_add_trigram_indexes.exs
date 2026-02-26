defmodule Slackex.Repo.Migrations.AddTrigramIndexes do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    CREATE INDEX users_username_trgm_idx
      ON users USING gist (username gist_trgm_ops)
    """

    execute """
    CREATE INDEX users_display_name_trgm_idx
      ON users USING gist (display_name gist_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS users_display_name_trgm_idx"
    execute "DROP INDEX IF EXISTS users_username_trgm_idx"
    execute "DROP EXTENSION IF EXISTS pg_trgm"
  end
end
