defmodule Slackex.Repo.Migrations.CreateInviteLinks do
  use Ecto.Migration

  def change do
    create table(:invite_links) do
      add :code, :string, null: false, size: 32
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :max_uses, :integer
      add :use_count, :integer, default: 0, null: false
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invite_links, [:code])
    create index(:invite_links, [:channel_id])
  end
end
