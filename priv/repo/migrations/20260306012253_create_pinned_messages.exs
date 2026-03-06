defmodule Slackex.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages) do
      add :message_id, references(:messages, type: :bigint, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :pinned_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:pinned_messages, [:message_id, :channel_id])
    create index(:pinned_messages, [:channel_id])
  end
end
