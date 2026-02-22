defmodule Slackex.Repo.Migrations.AddWriterEpoch do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :writer_epoch, :integer, null: false, default: 0
    end

    alter table(:dm_conversations) do
      add :writer_epoch, :integer, null: false, default: 0
    end
  end
end
