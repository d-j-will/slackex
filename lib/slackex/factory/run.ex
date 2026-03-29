defmodule Slackex.Factory.Run do
  @moduledoc """
  Ecto schema for factory pipeline runs. Tracks the lifecycle of a
  spec-to-implementation pipeline from queued through verification.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued implementing awaiting_verification verifying_tier2
               completed needs_review cancelled)

  schema "factory_runs" do
    field :spec_path, :string
    field :spec_commit_sha, :string
    field :status, :string, default: "queued"
    field :thread_message_id, :integer
    field :branch_name, :string
    field :claim_token, :string
    field :claimed_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :attempt, :integer, default: 1
    field :max_attempts, :integer, default: 3
    field :heartbeat_timeout_minutes, :integer, default: 10
    field :tier1_result, :map
    field :tier2_result, :map
    field :completed_at, :utc_datetime_usec

    belongs_to :queued_by, Slackex.Accounts.User
    belongs_to :channel, Slackex.Chat.Channel

    has_many :events, Slackex.Factory.Event, foreign_key: :factory_run_id

    timestamps(type: :utc_datetime_usec)
  end

  def queue_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :spec_path,
      :queued_by_id,
      :channel_id,
      :max_attempts,
      :heartbeat_timeout_minutes
    ])
    |> validate_required([:spec_path, :queued_by_id, :channel_id])
    |> validate_length(:spec_path, min: 1, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:queued_by_id)
    |> foreign_key_constraint(:channel_id)
  end

  def statuses, do: @statuses
end
