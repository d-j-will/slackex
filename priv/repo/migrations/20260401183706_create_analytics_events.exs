defmodule Slackex.Repo.Migrations.CreateAnalyticsEvents do
  use Ecto.Migration

  def change do
    create table(:analytics_events, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :event_type, :string, null: false
      add :event_category, :string, null: false
      add :event_name, :string, null: false
      add :user_id, references(:users, type: :bigint, on_delete: :nilify_all), null: true
      add :session_id, :string
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:analytics_events, [:event_type, :inserted_at])
    create index(:analytics_events, [:user_id, :inserted_at])
    create index(:analytics_events, [:metadata], using: :gin)
  end
end
