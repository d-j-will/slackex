defmodule Slackex.Chat.AbuseReport do
  @moduledoc """
  Schema for abuse reports. Allows users to report other users for spam,
  harassment, inappropriate content, phishing, or other violations.

  Uses a Snowflake bigint primary key. A unique partial index on
  (reporter_id, reported_user_id) WHERE status = 'open' prevents
  duplicate open reports for the same reporter-reported pair.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "abuse_reports" do
    belongs_to :reporter, Slackex.Accounts.User
    belongs_to :reported_user, Slackex.Accounts.User
    belongs_to :dm_conversation, Slackex.Chat.DMConversation

    field :message_id, :integer
    field :category, :string
    field :description, :string
    field :status, :string, default: "open"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @valid_categories ~w(spam harassment inappropriate_content phishing other)
  @valid_statuses ~w(open reviewed actioned dismissed)

  @castable_fields [
    :reporter_id,
    :reported_user_id,
    :dm_conversation_id,
    :message_id,
    :category,
    :description,
    :status,
    :metadata
  ]

  @doc """
  Validates an abuse report changeset.

  Requires reporter_id, reported_user_id, and category. Validates category
  inclusion in spam/harassment/inappropriate_content/phishing/other and
  status inclusion in open/reviewed/actioned/dismissed.
  """
  def changeset(report, attrs) do
    report
    |> cast(attrs, @castable_fields)
    |> validate_required([:reporter_id, :reported_user_id, :category])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:reporter_id, :reported_user_id],
      name: :abuse_reports_reporter_reported_open_idx,
      message: "already has an open report for this user"
    )
  end
end
