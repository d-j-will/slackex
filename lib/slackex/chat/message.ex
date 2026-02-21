defmodule Slackex.Chat.Message do
  @moduledoc """
  Message schema with Snowflake ID primary key and timestamp derivation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  schema "messages" do
    field :content, :string
    field :edited_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :dm_conversation, Slackex.Chat.DMConversation
    belongs_to :sender, Slackex.Accounts.User
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :content, :sender_id, :channel_id, :dm_conversation_id, :edited_at])
    |> validate_required([:id, :content, :sender_id])
    |> validate_length(:content, min: 1, max: 4000)
    |> put_inserted_at()
    |> validate_target()
  end

  defp put_inserted_at(changeset) do
    case get_change(changeset, :id) do
      nil ->
        changeset

      id ->
        ts_ms = Snowflake.extract_timestamp(id)
        inserted_at = DateTime.from_unix!(ts_ms * 1000, :microsecond)
        put_change(changeset, :inserted_at, inserted_at)
    end
  end

  def validate_target(changeset) do
    channel_id = get_field(changeset, :channel_id)
    dm_conversation_id = get_field(changeset, :dm_conversation_id)

    case {channel_id, dm_conversation_id} do
      {nil, nil} ->
        add_error(changeset, :base, "must have either channel_id or dm_conversation_id")

      {_, _} when not is_nil(channel_id) and not is_nil(dm_conversation_id) ->
        add_error(changeset, :base, "cannot have both channel_id and dm_conversation_id")

      _ ->
        changeset
    end
  end
end
