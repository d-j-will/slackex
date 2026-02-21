defmodule Slackex.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  def change do
    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :revoked_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])
    create index(:user_tokens, [:context, :revoked_at])
  end
end
