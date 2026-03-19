defmodule Slackex.Integrations.Webhook do
  @moduledoc """
  Webhook schema. Represents an incoming webhook that can post messages
  to a channel via a bot user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "webhooks" do
    field :name, :string
    field :token_hash, :string
    field :is_active, :boolean, default: true

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :bot_user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating a webhook.
  """
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :token_hash, :channel_id, :bot_user_id, :is_active])
    |> validate_required([:name, :token_hash, :channel_id, :bot_user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:bot_user_id)
  end
end
