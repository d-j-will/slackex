defmodule Slackex.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :platform, :string, size: 10, null: false
      add :device_name, :string, size: 100

      timestamps(type: :utc_datetime_usec)
    end

    create index(:device_tokens, [:user_id])
    create unique_index(:device_tokens, [:token])
  end
end
