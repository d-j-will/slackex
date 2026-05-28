defmodule Slackex.Repo.Migrations.SousB1ViewersAndFacets do
  @moduledoc """
  Slice B1 — role-lens data model.

  Creates the `viewers` (data-driven role-lenses) and `work_item_facets`
  (composite PK; per-(work_item, viewer) attention + reserved-for-B2 facet_text)
  tables. Drops the Slice-A single-viewer placeholder columns from `work_items`.

  Safety on the drops:
    * `:sous` flag is OFF in prod (no rows have meaningful attention/facet_text).
    * Slice A was a tracer bullet; B1 supersedes the single-viewer placeholder.
    * Per spec §10, the `/new-migration` safety hook is expected to WARN on the
      removes — this doc-comment acknowledges the safety analysis. If the hook
      BLOCKS, split into expand/contract per spec guidance.
  """

  use Ecto.Migration

  def change do
    create table(:viewers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :color, :string, null: false
      add :focus, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create table(:work_item_facets, primary_key: false) do
      add :work_item_id,
          references(:work_items, on_delete: :delete_all, type: :bigint),
          primary_key: true,
          null: false

      add :viewer_id,
          references(:viewers, on_delete: :delete_all, type: :string),
          primary_key: true,
          null: false

      add :attention, :string, null: false, default: "watch"
      add :facet_text, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Per-viewer board query lookup (`SELECT … WHERE viewer_id = $1`).
    create index(:work_item_facets, [:viewer_id, :work_item_id])

    # Drop the Slice-A single-viewer placeholders (see moduledoc).
    alter table(:work_items) do
      remove :attention, :string, null: false, default: "watch"
      remove :facet_text, :text
    end

    # Seed default viewers (just data — fully editable later via seeds/admin).
    execute(&seed_viewers/0, &delete_viewers/0)
  end

  defp seed_viewers do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    seeds = [
      %{
        id: "ceo",
        name: "CEO",
        color: "#d97757",
        focus: ["customers", "decisions", "risks", "wins"],
        position: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "cto",
        name: "CTO",
        color: "#7c5cff",
        focus: ["shipping", "risks", "decisions", "pulse"],
        position: 1,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "em",
        name: "EM",
        color: "#3ecf8e",
        focus: ["pulse", "decisions", "blockers"],
        position: 2,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "product",
        name: "Product",
        color: "#d97757",
        focus: ["voice", "shape", "customers"],
        position: 3,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "csm",
        name: "CSM",
        color: "#ff8fbf",
        focus: ["health", "moments", "calls", "renewals"],
        position: 4,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "arch",
        name: "Architect",
        color: "#3ecf8e",
        focus: ["stack", "horizon", "bench"],
        position: 5,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: "staff",
        name: "Staff Engineer",
        color: "#7c5cff",
        focus: ["distill", "package", "tension"],
        position: 6,
        inserted_at: now,
        updated_at: now
      }
    ]

    repo().insert_all("viewers", seeds)
  end

  defp delete_viewers do
    repo().delete_all("viewers")
  end
end
