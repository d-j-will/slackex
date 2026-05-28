defmodule Slackex.Repo.Migrations.SousB2FacetTextColumns do
  @moduledoc """
  Slice B2 — AI per-role facet text.

  Adds four nullable columns to `work_item_facets` to record per-(work_item, viewer)
  AI-generated facet text and its provenance. All four are nullable; no defaults,
  no backfill needed (existing rows have nil `facet_text` so the pill state
  derivation resolves to `:never_generated` correctly — see spec §4).

  Purely additive expand-only migration; `:sous` is OFF in prod so production
  rollback safety is identical to the empty case.
  """

  use Ecto.Migration

  def change do
    alter table(:work_item_facets) do
      add :facet_model, :string
      add :facet_prompt_version, :integer
      add :facet_generated_at, :utc_datetime_usec
      add :facet_stale_at, :utc_datetime_usec
    end
  end
end
