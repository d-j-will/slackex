defmodule Slackex.Sous.WorkItemEvent do
  @moduledoc """
  Append-only event log — the replay source of truth for a work item.
  Events are never updated or deleted (invariant #5). Payloads are
  self-describing (invariant #3) with string keys so the inline projection
  and a future replay-from-jsonb projection agree.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @types [:created, :state_changed, :card_posted, :attention_set]

  schema "work_item_events" do
    field :work_item_id, :integer
    field :type, Ecto.Enum, values: @types
    field :payload, :map, default: %{}
    field :actor_user_id, :integer
    field :inserted_at, :utc_datetime_usec
  end

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :work_item_id, :type, :payload, :actor_user_id])
    |> validate_required([:id, :work_item_id, :type])
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    case get_change(changeset, :id) do
      nil ->
        changeset

      id ->
        ts_ms = Snowflake.extract_timestamp(id)
        put_change(changeset, :inserted_at, DateTime.from_unix!(ts_ms * 1_000, :microsecond))
    end
  end
end
