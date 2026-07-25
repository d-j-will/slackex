defmodule Slackex.Andon.Channel do
  @moduledoc """
  A relay-enabled channel. A `channels` row is watched by the andon relay iff
  it has exactly one `andon_channels` row. The row also carries the status
  mirror's identity: `status_message_id` (the one edited-in-place message),
  `last_watermark` (the highest mirror update applied — C6 monotonicity), and
  `mirror` (the latest snapshot, so the hold card renders for a viewer who
  joins between updates rather than only for one watching live).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "andon_channels" do
    field :channel_id, :integer
    field :status_message_id, :integer
    field :last_watermark, :integer, default: 0
    field :mirror, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def enable_changeset(andon_channel, attrs) do
    andon_channel
    |> cast(attrs, [:channel_id])
    |> validate_required([:channel_id])
    |> unique_constraint(:channel_id)
    |> foreign_key_constraint(:channel_id)
  end

  @doc false
  def mirror_changeset(andon_channel, attrs) do
    cast(andon_channel, attrs, [:status_message_id, :last_watermark, :mirror])
  end
end
