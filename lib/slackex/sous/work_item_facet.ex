defmodule Slackex.Sous.WorkItemFacet do
  @moduledoc """
  Per-(work_item, viewer) facet row. Composite PK. Lazy: absence of a row means
  the default `:watch` (spec invariant #8). B1 stores `attention` only; B2 fills
  `facet_text` via the AI pipeline (`:facet_generated` event).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @attentions [:act, :watch, :know, :hidden]

  schema "work_item_facets" do
    field :work_item_id, :integer, primary_key: true
    field :viewer_id, :string, primary_key: true
    field :attention, Ecto.Enum, values: @attentions
    field :facet_text, :string
    field :updated_at, :utc_datetime_usec
  end

  @doc "The four attention values, in board sort-rank order."
  def attentions, do: @attentions

  def changeset(facet, attrs) do
    facet
    |> cast(attrs, [:work_item_id, :viewer_id, :attention, :facet_text, :updated_at])
    |> validate_required([:work_item_id, :viewer_id, :attention])
    |> put_updated_at()
  end

  defp put_updated_at(changeset) do
    case get_field(changeset, :updated_at) do
      nil ->
        put_change(changeset, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

      _ ->
        changeset
    end
  end
end
