defmodule Slackex.Chat.MessageReaction do
  @moduledoc """
  Schema for emoji reactions on messages. One record per user per emoji per message.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "message_reactions" do
    field :emoji, :string

    belongs_to :message, Slackex.Chat.Message
    belongs_to :user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :emoji])
    |> validate_required([:message_id, :user_id, :emoji])
    |> validate_length(:emoji, max: 50)
    |> unique_constraint([:message_id, :user_id, :emoji])
  end
end
