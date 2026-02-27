defmodule Slackex.Repo.Migrations.CreateUserTrustScores do
  use Ecto.Migration

  def change do
    create table(:user_trust_scores) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :decline_count, :integer, null: false, default: 0
      add :block_count, :integer, null: false, default: 0
      add :report_count, :integer, null: false, default: 0
      add :dm_restricted, :boolean, null: false, default: false
      add :dm_restricted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_trust_scores, [:user_id])
  end
end
