defmodule Slackex.Repo.Migrations.CreateAndonChannels do
  use Ecto.Migration

  def change do
    create table(:andon_channels) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      # The single edited-in-place status mirror message for this channel
      # (a Snowflake message id); nil until the first update_mirror creates it.
      add :status_message_id, :bigint
      # Highest applied mirror watermark; updates with a lower/equal watermark
      # are dropped (the relay's half of the monotonicity contract, C6).
      add :last_watermark, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # A channel is relay-enabled iff it has exactly one row.
    create unique_index(:andon_channels, [:channel_id])
  end
end
