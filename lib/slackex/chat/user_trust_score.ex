defmodule Slackex.Chat.UserTrustScore do
  @moduledoc """
  Schema for user trust scores. Tracks decline, block, and report counts
  to determine if a user's DM privileges should be restricted.

  One-to-one mapping with users -- each user has at most one trust score row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_trust_scores" do
    belongs_to :user, Slackex.Accounts.User

    field :decline_count, :integer, default: 0
    field :block_count, :integer, default: 0
    field :report_count, :integer, default: 0
    field :dm_restricted, :boolean, default: false
    field :dm_restricted_at, :utc_datetime_usec
    field :admin_flagged, :boolean, default: false
    field :admin_flagged_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @castable_fields [
    :user_id,
    :decline_count,
    :block_count,
    :report_count,
    :dm_restricted,
    :dm_restricted_at,
    :admin_flagged,
    :admin_flagged_at
  ]

  @doc """
  Validates a user trust score changeset.

  Requires user_id. Validates that counts are non-negative.
  """
  def changeset(trust_score, attrs) do
    trust_score
    |> cast(attrs, @castable_fields)
    |> validate_required([:user_id])
    |> validate_number(:decline_count, greater_than_or_equal_to: 0)
    |> validate_number(:block_count, greater_than_or_equal_to: 0)
    |> validate_number(:report_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id, message: "already has a trust score")
  end
end
