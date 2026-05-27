defmodule Slackex.Sous.WorkItemEventTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.WorkItemEvent
  alias Slackex.Infrastructure.Snowflake

  test "valid event derives inserted_at from id and accepts known types" do
    id = Snowflake.generate()

    cs =
      WorkItemEvent.changeset(%WorkItemEvent{}, %{
        id: id,
        work_item_id: 123,
        type: :created,
        payload: %{"title" => "x"},
        actor_user_id: 1
      })

    assert cs.valid?
    assert get_change(cs, :inserted_at)
  end

  test "rejects unknown event type" do
    cs = WorkItemEvent.changeset(%WorkItemEvent{}, %{id: 1, work_item_id: 1, type: :bogus})
    refute cs.valid?
    assert errors_on(cs)[:type]
  end
end
