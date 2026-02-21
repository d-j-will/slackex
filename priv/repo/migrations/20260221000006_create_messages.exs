defmodule Slackex.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :sender_id, references(:users, on_delete: :nilify_all)
      add :content, :text, null: false
      add :edited_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:channel_id, :id])
    create index(:messages, [:sender_id])

    execute(
      "CREATE INDEX messages_content_fts_idx ON messages USING GIN (to_tsvector('english', content))",
      "DROP INDEX IF EXISTS messages_content_fts_idx"
    )
  end
end
