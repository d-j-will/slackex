defmodule Slackex.Repo.Migrations.AddDmConversationIdToReadCursors do
  use Ecto.Migration

  def change do
    alter table(:read_cursors) do
      add :dm_conversation_id, references(:dm_conversations, on_delete: :delete_all), null: true
    end

    # Drop the existing primary key (user_id, channel_id) since channel_id can now be null
    execute(
      "ALTER TABLE read_cursors DROP CONSTRAINT read_cursors_pkey",
      "ALTER TABLE read_cursors ADD PRIMARY KEY (user_id, channel_id)"
    )

    # Make channel_id nullable (was NOT NULL from original migration)
    execute(
      "ALTER TABLE read_cursors ALTER COLUMN channel_id DROP NOT NULL",
      "ALTER TABLE read_cursors ALTER COLUMN channel_id SET NOT NULL"
    )

    # Exactly one of channel_id or dm_conversation_id must be non-null
    create constraint(:read_cursors, :channel_or_dm_exclusive,
      check: """
      (channel_id IS NOT NULL AND dm_conversation_id IS NULL) OR
      (channel_id IS NULL AND dm_conversation_id IS NOT NULL)
      """
    )

    # New composite primary key -- use a unique index instead since Ecto
    # doesn't support multi-column PKs with nullable columns easily
    create unique_index(:read_cursors, [:user_id, :channel_id],
      where: "channel_id IS NOT NULL",
      name: :read_cursors_user_channel_unique
    )

    create unique_index(:read_cursors, [:user_id, :dm_conversation_id],
      where: "dm_conversation_id IS NOT NULL",
      name: :read_cursors_user_dm_unique
    )
  end
end
