defmodule Slackex.Sous.WorkItem do
  @moduledoc """
  The work-item projection (authoritative read model). Maintained inline by
  `Slackex.Sous` commands via `Slackex.Sous.Projection`; every field is
  reconstructable from the `work_item_events` log (spec §6, invariant #6).

  B1: per-viewer `attention` (and later `facet_text`) live on
  `Slackex.Sous.WorkItemFacet`, not here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @states [:order, :mise, :pass, :walked]
  @kinds [:decision]

  schema "work_items" do
    field :kind, Ecto.Enum, values: @kinds
    field :state, Ecto.Enum, values: @states
    field :title, :string
    field :people, :map, default: %{}
    field :channel_id, :integer
    field :thread_root_message_id, :integer
    field :card_message_id, :integer
    field :moved_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    has_one :decision, Slackex.Sous.Decision, foreign_key: :work_item_id, references: :id
    has_many :events, Slackex.Sous.WorkItemEvent, foreign_key: :work_item_id, references: :id
    has_many :facets, Slackex.Sous.WorkItemFacet, foreign_key: :work_item_id, references: :id
  end

  def states, do: @states
  def kinds, do: @kinds

  def changeset(work_item, attrs) do
    work_item
    |> cast(attrs, [
      :id,
      :kind,
      :state,
      :title,
      :people,
      :channel_id,
      :thread_root_message_id,
      :card_message_id,
      :moved_at
    ])
    |> validate_required([:id, :kind, :state, :title])
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
