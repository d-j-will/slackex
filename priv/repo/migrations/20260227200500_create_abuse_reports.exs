defmodule Slackex.Repo.Migrations.CreateAbuseReports do
  use Ecto.Migration

  def change do
    create table(:abuse_reports, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :reporter_id, references(:users, on_delete: :nothing), null: false
      add :reported_user_id, references(:users, on_delete: :nothing), null: false
      add :dm_conversation_id, references(:dm_conversations, on_delete: :nothing)
      add :message_id, :bigint

      add :category, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "open"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:abuse_reports, [:reporter_id])
    create index(:abuse_reports, [:reported_user_id])
    create index(:abuse_reports, [:dm_conversation_id])

    create unique_index(:abuse_reports, [:reporter_id, :reported_user_id],
      where: "status = 'open'",
      name: :abuse_reports_reporter_reported_open_idx
    )
  end
end
