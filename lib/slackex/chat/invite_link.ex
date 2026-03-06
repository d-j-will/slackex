defmodule Slackex.Chat.InviteLink do
  @moduledoc """
  Schema for channel invite links with optional expiry and usage limits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "invite_links" do
    field :code, :string
    field :max_uses, :integer
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :created_by, Slackex.Accounts.User, foreign_key: :created_by_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:code, :channel_id, :created_by_id, :max_uses, :expires_at])
    |> validate_required([:channel_id])
    |> put_code_if_missing()
    |> unique_constraint(:code)
  end

  defp put_code_if_missing(changeset) do
    if get_field(changeset, :code) do
      changeset
    else
      put_change(changeset, :code, generate_code())
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) |> binary_part(0, 22)
  end
end
