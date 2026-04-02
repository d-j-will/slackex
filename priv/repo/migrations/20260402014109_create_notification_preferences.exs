defmodule Slackex.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  def change do
    create table(:notification_preferences) do
      add :user_id, references(:users, type: :bigint, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, type: :bigint, on_delete: :delete_all), null: true
      add :level, :string, null: false, default: "all"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_preferences, [:user_id],
             where: "channel_id IS NULL",
             name: :notification_preferences_user_global_idx
           )

    create unique_index(:notification_preferences, [:user_id, :channel_id],
             where: "channel_id IS NOT NULL",
             name: :notification_preferences_user_channel_idx
           )

    create index(:notification_preferences, [:user_id])

    # Backfill global defaults for existing users
    execute(
      "INSERT INTO notification_preferences (user_id, channel_id, level, inserted_at, updated_at) SELECT id, NULL, 'all', NOW(), NOW() FROM users",
      "DELETE FROM notification_preferences WHERE channel_id IS NULL"
    )
  end
end
