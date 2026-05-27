defmodule Slackex.Sous.ProjectionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload),
    do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :created builds the work item and decision attrs" do
    created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Adopt ES",
        "state" => "mise",
        "facet_text" => "Adopt ES",
        "attention" => "watch",
        "people" => %{"lead" => 7, "stakeholders" => [8, 9]},
        "what" => "Use event sourcing",
        "why" => "audit",
        "next" => "spike",
        "channel_id" => 100,
        "thread_root_message_id" => 555,
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      })

    state = Projection.fold([created])

    assert state.work_item.id == 10
    assert state.work_item.kind == :decision
    assert state.work_item.state == :mise
    assert state.work_item.attention == :watch
    assert state.work_item.channel_id == 100
    assert state.work_item.card_message_id == nil
    assert state.decision.what == "Use event sourcing"
  end

  test "fold :state_changed updates state and moved_at" do
    events = [
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "x",
        "state" => "mise",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      }),
      ev(2, :state_changed, %{
        "from" => "mise",
        "to" => "pass",
        "moved_at" => "2026-05-27T11:00:00.000000Z"
      })
    ]

    state = Projection.fold(events)
    assert state.work_item.state == :pass
    assert state.work_item.moved_at == ~U[2026-05-27 11:00:00.000000Z]
  end

  test "fold :card_posted sets card_message_id" do
    events = [
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "x",
        "state" => "mise",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      }),
      ev(3, :card_posted, %{"card_message_id" => 9999})
    ]

    state = Projection.fold(events)
    assert state.work_item.card_message_id == 9999
  end
end
