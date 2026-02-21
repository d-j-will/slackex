defmodule Slackex.Repo.Migrations.CreateDmConversations do
  use Ecto.Migration

  def change do
    create table(:dm_conversations) do
      add :user_a_id, references(:users, on_delete: :delete_all), null: false
      add :user_b_id, references(:users, on_delete: :delete_all), null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:dm_conversations, [:user_a_id, :user_b_id])
    create index(:dm_conversations, [:user_b_id])

    execute(
      """
      ALTER TABLE dm_conversations ADD CONSTRAINT dm_conversations_user_order_check
        CHECK (user_a_id < user_b_id)
      """,
      "ALTER TABLE dm_conversations DROP CONSTRAINT IF EXISTS dm_conversations_user_order_check"
    )

    alter table(:messages) do
      add :dm_conversation_id, references(:dm_conversations, on_delete: :delete_all)
    end

    create index(:messages, [:dm_conversation_id, :id])

    execute(
      """
      ALTER TABLE messages ADD CONSTRAINT messages_target_check
        CHECK (
          (channel_id IS NOT NULL AND dm_conversation_id IS NULL) OR
          (channel_id IS NULL AND dm_conversation_id IS NOT NULL)
        )
      """,
      "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_target_check"
    )
  end
end
