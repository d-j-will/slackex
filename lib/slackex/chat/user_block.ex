defmodule Slackex.Chat.UserBlock do
  @moduledoc """
  Schema for user blocks. A block prevents a blocked user from sending
  direct messages to the blocker. Blocks are immutable (create/delete only).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_blocks" do
    belongs_to :blocker, Slackex.Accounts.User
    belongs_to :blocked, Slackex.Accounts.User

    field :reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Validates a user block changeset.

  Requires blocker_id and blocked_id. Rejects self-blocking.
  """
  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, [:blocker_id, :blocked_id, :reason])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_not_self_block()
    |> unique_constraint([:blocker_id, :blocked_id],
      message: "has already blocked this user"
    )
  end

  defp validate_not_self_block(changeset) do
    blocker_id = get_field(changeset, :blocker_id)
    blocked_id = get_field(changeset, :blocked_id)

    if blocker_id && blocked_id && blocker_id == blocked_id do
      add_error(changeset, :blocked_id, "cannot block yourself")
    else
      changeset
    end
  end
end
