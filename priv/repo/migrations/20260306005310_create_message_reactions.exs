defmodule Slackex.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  def change do
    create table(:message_reactions) do
      add :message_id, :bigint, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false, size: 50

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
    create index(:message_reactions, [:message_id])
  end
end
