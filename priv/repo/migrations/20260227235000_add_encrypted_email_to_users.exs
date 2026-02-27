defmodule Slackex.Repo.Migrations.AddEncryptedEmailToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :encrypted_email, :binary
      add :email_hash, :binary
    end

    # Allow old email column to be null (schema no longer writes to it)
    execute "ALTER TABLE users ALTER COLUMN email DROP NOT NULL"

    # Replace old plaintext unique index with hash-based unique index
    drop_if_exists unique_index(:users, [:email])
    create unique_index(:users, [:email_hash])
  end

  def down do
    drop_if_exists unique_index(:users, [:email_hash])
    create unique_index(:users, [:email])

    execute "ALTER TABLE users ALTER COLUMN email SET NOT NULL"

    alter table(:users) do
      remove :encrypted_email
      remove :email_hash
    end
  end
end
