defmodule Slackex.Repo.Migrations.CreateReadCursors do
  use Ecto.Migration

  def change do
    create table(:read_cursors, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true

      add :channel_id, references(:channels, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :last_read_message_id, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
