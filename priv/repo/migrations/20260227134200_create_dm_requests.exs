defmodule Slackex.Repo.Migrations.CreateDmRequests do
  use Ecto.Migration

  def change do
    create table(:dm_requests, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :sender_id, references(:users, on_delete: :nothing), null: false
      add :recipient_id, references(:users, on_delete: :nothing), null: false
      add :dm_conversation_id, references(:dm_conversations, on_delete: :nothing)

      add :preview_text, :string, size: 500
      add :status, :string, null: false, default: "pending"
      add :responded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:dm_requests, [:recipient_id])
    create index(:dm_requests, [:dm_conversation_id])

    create unique_index(:dm_requests, [:sender_id, :recipient_id],
      where: "status = 'pending'",
      name: :dm_requests_sender_recipient_pending_idx
    )
  end
end
