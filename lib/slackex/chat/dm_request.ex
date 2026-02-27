defmodule Slackex.Chat.DMRequest do
  @moduledoc """
  Schema for DM requests. A request allows a user to request a direct message
  conversation with another user. Status transitions: pending -> accepted | declined.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "dm_requests" do
    belongs_to :sender, Slackex.Accounts.User
    belongs_to :recipient, Slackex.Accounts.User
    belongs_to :dm_conversation, Slackex.Chat.DMConversation

    field :preview_text, Slackex.Encrypted.Binary, source: :encrypted_preview_text
    field :status, :string, default: "pending"
    field :responded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_statuses ~w(pending accepted declined)

  @doc """
  Validates a DM request changeset.

  Requires sender_id and recipient_id. Validates preview_text max 500 chars
  and status inclusion in pending/accepted/declined.
  """
  def changeset(dm_request, attrs) do
    dm_request
    |> cast(attrs, [
      :sender_id,
      :recipient_id,
      :preview_text,
      :status,
      :dm_conversation_id,
      :responded_at
    ])
    |> validate_required([:sender_id, :recipient_id])
    |> validate_preview_text_length(max: 500)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:sender_id, :recipient_id],
      name: :dm_requests_sender_recipient_pending_idx,
      message: "already has a pending request to this user"
    )
  end

  defp validate_preview_text_length(changeset, opts) do
    case get_change(changeset, :preview_text) do
      nil ->
        changeset

      value when is_binary(value) ->
        max = Keyword.get(opts, :max)

        if max && String.length(value) > max do
          add_error(changeset, :preview_text, "should be at most %{count} character(s)",
            count: max,
            validation: :length,
            kind: :max,
            type: :string
          )
        else
          changeset
        end

      _other ->
        changeset
    end
  end
end
