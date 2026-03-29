defmodule Slackex.Repo.Migrations.CreateFactoryTables do
  use Ecto.Migration

  def change do
    create table(:factory_runs) do
      add :spec_path, :string, null: false
      add :spec_commit_sha, :string
      add :status, :string, null: false, default: "queued"
      add :queued_by_id, references(:users, on_delete: :restrict), null: false
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :thread_message_id, :bigint
      add :branch_name, :string
      add :claim_token, :string
      add :claimed_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :attempt, :integer, null: false, default: 1
      add :max_attempts, :integer, null: false, default: 3
      add :heartbeat_timeout_minutes, :integer, null: false, default: 10
      add :tier1_result, :map
      add :tier2_result, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:factory_runs, [:status])
    create index(:factory_runs, [:queued_by_id])
    create index(:factory_runs, [:status, :queued_by_id])

    create table(:factory_events) do
      add :factory_run_id, references(:factory_runs, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :from_status, :string
      add :to_status, :string
      add :message, :text
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:factory_events, [:factory_run_id])
  end
end
