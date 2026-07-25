defmodule Slackex.Repo.Migrations.AndonChannelsMirrorSnapshot do
  use Ecto.Migration

  def change do
    # The latest mirror snapshot, kept so the hold card renders for a viewer
    # who joins between updates. The edited text message stays the fallback
    # and the notification body; this is the structured half behind it.
    alter table(:andon_channels) do
      add :mirror, :map
    end
  end
end
