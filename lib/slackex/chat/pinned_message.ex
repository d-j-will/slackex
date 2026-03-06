defmodule Slackex.Chat.PinnedMessage do
  @moduledoc """
  Schema for pinned messages in a channel.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "pinned_messages" do
    belongs_to :message, Slackex.Chat.Message
    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :pinned_by, Slackex.Accounts.User, foreign_key: :pinned_by_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:message_id, :channel_id, :pinned_by_id])
    |> validate_required([:message_id, :channel_id])
    |> unique_constraint([:message_id, :channel_id])
  end
end
