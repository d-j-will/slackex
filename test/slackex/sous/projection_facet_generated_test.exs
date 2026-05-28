defmodule Slackex.Sous.ProjectionFacetGeneratedTest do
  @moduledoc """
  Folds for the B2 `:facet_generated` event. Covers invariants #15-17 (last-
  write-wins on the field; lazy row creation with `:watch` default; pure replay
  reads text from the event payload — no LLM call site in the projection).
  """

  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload),
    do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  defp created_payload do
    %{
      "kind" => "decision",
      "title" => "x",
      "state" => "mise",
      "what" => "w",
      "moved_at" => "2026-05-27T10:00:00.000000Z"
    }
  end

  defp facet_payload(viewer_id, text) do
    %{
      "viewer_id" => viewer_id,
      "facet_text" => text,
      "model" => "stub",
      "prompt_version" => 1,
      "generated_at" => "2026-05-28T10:00:00.000000Z",
      "state_version" => 0
    }
  end

  test "lazy row creation for a viewer with no prior attention (#16)" do
    events = [
      ev(1, :created, created_payload()),
      ev(2, :facet_generated, facet_payload("cto", "cto-prism"))
    ]

    state = Projection.fold(events)

    assert state.facets["cto"].attention == :watch
    assert state.facets["cto"].facet_text == "cto-prism"
    assert state.facets["cto"].facet_model == "stub"
    assert state.facets["cto"].facet_prompt_version == 1
    assert %DateTime{} = state.facets["cto"].facet_generated_at
    assert state.facets["cto"].facet_stale_at == nil
  end

  test "attention_set then facet_generated preserves attention and adds text" do
    events = [
      ev(1, :created, created_payload()),
      ev(2, :attention_set, %{"viewer_id" => "cto", "attention" => "act", "actor_user_id" => 1}),
      ev(3, :facet_generated, facet_payload("cto", "cto-prism"))
    ]

    state = Projection.fold(events)

    assert state.facets["cto"].attention == :act
    assert state.facets["cto"].facet_text == "cto-prism"
  end

  test "facet_generated then attention_set preserves text and updates attention" do
    events = [
      ev(1, :created, created_payload()),
      ev(2, :facet_generated, facet_payload("cto", "cto-prism")),
      ev(3, :attention_set, %{"viewer_id" => "cto", "attention" => "hidden", "actor_user_id" => 1})
    ]

    state = Projection.fold(events)

    assert state.facets["cto"].facet_text == "cto-prism"
    assert state.facets["cto"].attention == :hidden
  end

  test "two facet_generated events for same viewer: last-write-wins on field (#15)" do
    events = [
      ev(1, :created, created_payload()),
      ev(2, :facet_generated, facet_payload("cto", "first")),
      ev(3, :facet_generated, facet_payload("cto", "second"))
    ]

    state = Projection.fold(events)
    assert state.facets["cto"].facet_text == "second"
  end

  test "facet_generated always clears facet_stale_at" do
    # Even if a prior :state_changed clause set stale_at, generation clears it.
    # (Spec §5 step 5: "generation always clears stale".)
    state =
      Projection.apply_event(
        %{
          facets: %{
            "cto" => %{attention: :act, facet_text: "old", facet_stale_at: DateTime.utc_now()}
          }
        },
        ev(99, :facet_generated, facet_payload("cto", "new"))
      )

    assert state.facets["cto"].facet_stale_at == nil
    assert state.facets["cto"].facet_text == "new"
    assert state.facets["cto"].attention == :act
  end
end
