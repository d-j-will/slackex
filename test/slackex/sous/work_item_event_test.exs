defmodule Slackex.Sous.WorkItemEventTest do
  use Slackex.DataCase, async: true

  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Sous.WorkItemEvent

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

  test "B2 :facet_generated round-trips through the schema" do
    id = Snowflake.generate()

    cs =
      WorkItemEvent.changeset(%WorkItemEvent{}, %{
        id: id,
        work_item_id: 123,
        type: :facet_generated,
        payload: %{
          "viewer_id" => "cto",
          "facet_text" => "the prism text",
          "model" => "stub",
          "prompt_version" => 1,
          "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "state_version" => 0
        },
        actor_user_id: nil
      })

    assert cs.valid?
    assert :facet_generated in WorkItemEvent.types()
  end
end
