defmodule Slackex.Sous.ProjectionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload),
    do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :created builds work_item + decision; facets start empty (invariant #8)" do
    created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Adopt ES",
        "state" => "mise",
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
    assert state.work_item.channel_id == 100
    assert state.work_item.card_message_id == nil
    refute Map.has_key?(state.work_item, :attention)
    refute Map.has_key?(state.work_item, :facet_text)
    assert state.facets == %{}
    assert state.decision.what == "Use event sourcing"
  end

  test "fold :created IGNORES Slice-A facet_text/attention payload keys (invariant #9)" do
    legacy_created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Slice-A legacy",
        "state" => "mise",
        "facet_text" => "Slice-A legacy",
        "attention" => "act",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      })

    state = Projection.fold([legacy_created])
    refute Map.has_key?(state.work_item, :attention)
    refute Map.has_key?(state.work_item, :facet_text)
    assert state.facets == %{}
  end

  test "fold :state_changed updates state + moved_at; facets untouched" do
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
    assert state.facets == %{}
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
