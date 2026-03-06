defmodule Slackex.Repo.Migrations.AddThreadsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :parent_message_id, :bigint
      add :reply_count, :integer, default: 0, null: false
    end

    create index(:messages, [:parent_message_id], where: "parent_message_id IS NOT NULL")
  end
end
