defmodule Slackex.Chat.Subscription do
  @moduledoc """
  Channel subscription schema with role-based membership.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "subscriptions" do
    field :role, :string, default: "member"
    field :muted, :boolean, default: false

    belongs_to :user, Slackex.Accounts.User, primary_key: true
    belongs_to :channel, Slackex.Chat.Channel, primary_key: true

    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :channel_id, :role, :muted])
    |> validate_required([:user_id, :channel_id])
    |> validate_inclusion(:role, ["owner", "admin", "member", "viewer"])
  end
end
