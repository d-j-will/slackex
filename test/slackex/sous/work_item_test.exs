defmodule Slackex.Sous.WorkItemTest do
  use Slackex.DataCase, async: true

  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Sous.WorkItem

  test "changeset derives inserted_at from the Snowflake id" do
    id = Snowflake.generate()

    cs =
      WorkItem.changeset(%WorkItem{}, %{
        id: id,
        kind: :decision,
        state: :mise,
        title: "Adopt event sourcing",
        moved_at: DateTime.utc_now()
      })

    assert cs.valid?

    assert get_change(cs, :inserted_at) ==
             DateTime.from_unix!(Snowflake.extract_timestamp(id) * 1_000, :microsecond)
  end

  test "requires id, kind, state, title" do
    cs = WorkItem.changeset(%WorkItem{}, %{})
    refute cs.valid?
    assert %{id: _, kind: _, state: _, title: _} = errors_on(cs)
  end

  test "rejects an unknown state" do
    cs = WorkItem.changeset(%WorkItem{}, %{id: 1, kind: :decision, state: :nope, title: "x"})
    refute cs.valid?
    assert errors_on(cs)[:state]
  end
end
