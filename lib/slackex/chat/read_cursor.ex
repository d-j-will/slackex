defmodule Slackex.Chat.ReadCursor do
  @moduledoc """
  Read cursor schema tracking last-read message per user per channel or DM conversation.

  Exactly one of channel_id or dm_conversation_id must be non-null,
  enforced by a CHECK constraint at the database level.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "read_cursors" do
    field :last_read_message_id, :integer

    belongs_to :user, Slackex.Accounts.User, primary_key: true
    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :dm_conversation, Slackex.Chat.DMConversation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(read_cursor, attrs) do
    read_cursor
    |> cast(attrs, [:user_id, :channel_id, :dm_conversation_id, :last_read_message_id])
    |> validate_required([:user_id, :last_read_message_id])
    |> validate_exclusive_target()
  end

  defp validate_exclusive_target(changeset) do
    channel_id = get_field(changeset, :channel_id)
    dm_conversation_id = get_field(changeset, :dm_conversation_id)

    case {channel_id, dm_conversation_id} do
      {nil, nil} ->
        add_error(changeset, :base, "must have either channel_id or dm_conversation_id")

      {cid, did} when not is_nil(cid) and not is_nil(did) ->
        add_error(changeset, :base, "cannot have both channel_id and dm_conversation_id")

      _ ->
        changeset
    end
  end
end
