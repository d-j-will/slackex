defmodule Slackex.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :name, :string, size: 100, null: false
      add :slug, :string, size: 100, null: false
      add :description, :text
      add :creator_id, references(:users, on_delete: :nilify_all)
      add :is_private, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:slug])
    create index(:channels, [:creator_id])
  end
end
