defmodule Slackex.Repo.Migrations.AddUniqueIndexToLinkPreviews do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create unique_index(:link_previews, [:message_id, :url], concurrently: true)
  end
end
