defmodule Slackex.Chat.Channel do
  @moduledoc """
  Channel schema with slug generation and uniqueness constraints.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "channels" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :is_private, :boolean, default: false

    belongs_to :creator, Slackex.Accounts.User
    has_many :subscriptions, Slackex.Chat.Subscription
    has_many :members, through: [:subscriptions, :user]
    has_many :messages, Slackex.Chat.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :creator_id, :is_private])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 100)
    |> put_slug()
    |> unique_constraint(:slug)
  end

  defp put_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
