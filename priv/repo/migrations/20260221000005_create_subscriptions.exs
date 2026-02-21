defmodule Slackex.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true

      add :channel_id, references(:channels, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :role, :string, size: 20, default: "member"
      add :muted, :boolean, default: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:subscriptions, [:channel_id])
  end
end
