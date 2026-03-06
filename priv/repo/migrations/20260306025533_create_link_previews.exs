defmodule Slackex.Repo.Migrations.CreateLinkPreviews do
  use Ecto.Migration

  def change do
    create table(:link_previews) do
      add :message_id, :bigint, null: false
      add :url, :string, null: false
      add :title, :string, size: 200
      add :description, :string, size: 500
      add :site_name, :string, size: 100
      add :image_url, :string
      add :favicon_url, :string
      add :status, :string, null: false, default: "pending"
      add :blocked_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:link_previews, [:message_id])
  end
end
