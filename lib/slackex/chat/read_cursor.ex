defmodule Slackex.Chat.ReadCursor do
  @moduledoc """
  Read cursor schema tracking last-read message per user per channel.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "read_cursors" do
    field :last_read_message_id, :integer

    belongs_to :user, Slackex.Accounts.User, primary_key: true
    belongs_to :channel, Slackex.Chat.Channel, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(read_cursor, attrs) do
    read_cursor
    |> cast(attrs, [:user_id, :channel_id, :last_read_message_id])
    |> validate_required([:user_id, :channel_id, :last_read_message_id])
  end
end
