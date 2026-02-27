defmodule Slackex.Repo.Migrations.AddUpdatedAtToDmConversations do
  use Ecto.Migration

  def change do
    alter table(:dm_conversations) do
      add :updated_at, :utc_datetime_usec
    end

    # Backfill existing rows: set updated_at = inserted_at
    execute(
      "UPDATE dm_conversations SET updated_at = inserted_at WHERE updated_at IS NULL",
      ""
    )

    # Now make it non-null with a DB default
    alter table(:dm_conversations) do
      modify :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
