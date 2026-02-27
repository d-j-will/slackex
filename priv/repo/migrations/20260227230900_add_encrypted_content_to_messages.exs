defmodule Slackex.Repo.Migrations.AddEncryptedContentToMessages do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :encrypted_content, :binary
    end

    execute "ALTER TABLE messages ALTER COLUMN content DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE messages ALTER COLUMN content SET NOT NULL"

    alter table(:messages) do
      remove :encrypted_content
    end
  end
end
