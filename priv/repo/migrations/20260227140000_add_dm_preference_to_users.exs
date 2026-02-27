defmodule Slackex.Repo.Migrations.AddDmPreferenceToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :dm_preference, :string, default: "anyone", null: false
    end
  end
end
