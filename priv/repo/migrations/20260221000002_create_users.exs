defmodule Slackex.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, size: 50, null: false
      add :display_name, :string, size: 100
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :avatar_url, :text
      add :status, :string, size: 20, default: "offline"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:email])
  end
end
