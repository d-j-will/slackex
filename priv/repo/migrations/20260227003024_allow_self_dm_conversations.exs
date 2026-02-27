defmodule Slackex.Repo.Migrations.AllowSelfDmConversations do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE dm_conversations DROP CONSTRAINT dm_conversations_user_order_check")

    execute("""
    ALTER TABLE dm_conversations ADD CONSTRAINT dm_conversations_user_order_check
      CHECK (user_a_id <= user_b_id)
    """)
  end

  def down do
    execute("ALTER TABLE dm_conversations DROP CONSTRAINT dm_conversations_user_order_check")

    execute("""
    ALTER TABLE dm_conversations ADD CONSTRAINT dm_conversations_user_order_check
      CHECK (user_a_id < user_b_id)
    """)
  end
end
