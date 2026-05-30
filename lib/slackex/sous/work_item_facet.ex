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
    field :facet_model, :string
    field :facet_prompt_version, :integer
    field :facet_generated_at, :utc_datetime_usec
    field :facet_stale_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The four attention values, in board sort-rank order."
  def attentions, do: @attentions

  @b2_fields [
    :work_item_id,
    :viewer_id,
    :attention,
    :facet_text,
    :facet_model,
    :facet_prompt_version,
    :facet_generated_at,
    :facet_stale_at,
    :updated_at
  ]

  def changeset(facet, attrs) do
    facet
    |> cast(attrs, @b2_fields)
    |> validate_required([:work_item_id, :viewer_id, :attention])
    |> put_updated_at()
  end

  @doc """
  Pure pill-state derivation from a facet row (spec §4).

  Branches in order:
    1. `row == nil` OR `row.facet_text == nil` -> `:never_generated`
    2. `row.facet_stale_at != nil` -> `:stale`
    3. `row.facet_prompt_version < FacetPrompt.prompt_version()` -> `:stale`
    4. otherwise -> `:fresh`

  The runtime states (`:generating`, `:failed`, `:not_configured`) are layered
  on top of this by the caller (Drawer component / LiveView) from socket state —
  they are not derivable from the persisted row.
  """
  @spec state(%__MODULE__{} | nil) :: atom()
  def state(row_or_nil) do
    cond do
      is_nil(row_or_nil) or is_nil(row_or_nil.facet_text) -> :never_generated
      not is_nil(row_or_nil.facet_stale_at) -> :stale
      row_or_nil.facet_prompt_version < Slackex.Sous.FacetPrompt.prompt_version() -> :stale
      true -> :fresh
    end
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
