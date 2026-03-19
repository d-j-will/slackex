defmodule Slackex.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :bot_user_id, references(:users, on_delete: :delete_all), null: false
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhooks, [:token_hash])
    create index(:webhooks, [:channel_id])
  end
end
