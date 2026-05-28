defmodule Slackex.Sous.ProjectionAttentionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload),
    do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :attention_set upserts per-viewer attention into the facets map" do
    events = [
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "x",
        "state" => "mise",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      }),
      ev(2, :attention_set, %{"viewer_id" => "cto", "attention" => "act", "actor_user_id" => 42}),
      ev(3, :attention_set, %{"viewer_id" => "ceo", "attention" => "know", "actor_user_id" => 42})
    ]

    state = Projection.fold(events)

    assert state.facets["cto"].attention == :act
    assert state.facets["ceo"].attention == :know
    # Other viewers absent → lazy default (invariant #8)
    refute Map.has_key?(state.facets, "em")
  end

  test "repeated :attention_set events are last-write-wins on the row (spec §5)" do
    events = [
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "x",
        "state" => "mise",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      }),
      ev(2, :attention_set, %{"viewer_id" => "cto", "attention" => "act", "actor_user_id" => 1}),
      ev(3, :attention_set, %{"viewer_id" => "cto", "attention" => "know", "actor_user_id" => 2}),
      ev(4, :attention_set, %{"viewer_id" => "cto", "attention" => "hidden", "actor_user_id" => 3})
    ]

    state = Projection.fold(events)
    assert state.facets["cto"].attention == :hidden
  end
end
