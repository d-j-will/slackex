defmodule Slackex.Chat.DMConversation do
  @moduledoc """
  Direct message conversation schema with user ordering invariant (user_a_id <= user_b_id).
  Allows self-DMs (user_a_id == user_b_id) for personal notes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "dm_conversations" do
    belongs_to :user_a, Slackex.Accounts.User
    belongs_to :user_b, Slackex.Accounts.User

    has_many :messages, Slackex.Chat.Message

    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
    field :updated_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(dm_conversation, attrs) do
    dm_conversation
    |> cast(attrs, [:user_a_id, :user_b_id])
    |> validate_required([:user_a_id, :user_b_id])
    |> normalize_user_order()
    |> unique_constraint([:user_a_id, :user_b_id])
  end

  @doc """
  Ensures user_a_id <= user_b_id to prevent duplicate DM conversations
  with swapped user IDs. Allows user_a_id == user_b_id for self-DMs.
  """
  def normalize_user_order(changeset) do
    user_a_id = get_field(changeset, :user_a_id)
    user_b_id = get_field(changeset, :user_b_id)

    if user_a_id && user_b_id && user_a_id > user_b_id do
      changeset
      |> put_change(:user_a_id, user_b_id)
      |> put_change(:user_b_id, user_a_id)
    else
      changeset
    end
  end
end
