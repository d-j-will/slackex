defmodule Slackex.Repo.Migrations.CreateMcpTokens do
  use Ecto.Migration

  def change do
    create table(:mcp_tokens) do
      add :token_hash, :string, null: false
      add :name, :string, null: false
      add :bot_user_id, references(:users, on_delete: :nothing), null: false
      add :is_active, :boolean, default: true, null: false
      add :last_used_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:mcp_tokens, [:token_hash])
    create index(:mcp_tokens, [:bot_user_id])
  end
end
