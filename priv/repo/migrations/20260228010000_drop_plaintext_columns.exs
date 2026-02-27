defmodule Slackex.Repo.Migrations.DropPlaintextColumns do
  @moduledoc """
  Drops the original plaintext columns after data has been migrated
  to encrypted form by `mix slackex.encrypt_existing`.

  The Ecto schemas already use `source: :encrypted_*` mappings, so no
  schema changes are needed after this migration runs.

  ## Run order

  1. `mix slackex.encrypt_existing` -- encrypts all existing plaintext data
  2. `mix ecto.migrate`             -- applies this migration to drop plaintext columns
  """

  use Ecto.Migration

  def up do
    alter table(:messages) do
      remove :content
    end

    alter table(:users) do
      remove :email
    end

    alter table(:dm_requests) do
      remove :preview_text
    end

    alter table(:abuse_reports) do
      remove :description
      remove :metadata
    end
  end

  def down do
    alter table(:messages) do
      add :content, :text
    end

    alter table(:users) do
      add :email, :string
    end

    alter table(:dm_requests) do
      add :preview_text, :string
    end

    alter table(:abuse_reports) do
      add :description, :string
      add :metadata, :map
    end
  end
end
