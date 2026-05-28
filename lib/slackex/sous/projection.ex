defmodule Slackex.Sous.Projection do
  @moduledoc """
  Pure fold from a work item's event log to its projected state.

  Used INLINE by `Slackex.Sous` commands to compute the row to persist, and
  reusable by a future event-replay projector — the same function, satisfying
  invariant #4. Payloads use string keys (jsonb round-trips as strings), so the
  inline path and a replay-from-DB path produce identical results.

  Returns `%{work_item: map | nil, decision: map | nil}` where the inner maps are
  attribute maps suitable for `WorkItem.changeset/2` / `Decision.changeset/2`.
  """

  alias Slackex.Sous.WorkItemEvent

  # B1 (invariant #8/#9): the @attentions atom set lives here so the projection
  # can `String.to_existing_atom/1` payload strings even after the Slice-A
  # `@attentions` attribute moved off WorkItem. Until T3 (`WorkItemFacet`) lands,
  # this module is the only producer that materialises these atoms.
  @attention_atoms [:act, :watch, :know, :hidden]
  def attention_atoms, do: @attention_atoms

  @type state :: %{work_item: map() | nil, decision: map() | nil, facets: map()}

  @spec initial() :: state()
  def initial, do: %{work_item: nil, decision: nil, facets: %{}}

  def fold(events) when is_list(events) do
    Enum.reduce(events, initial(), &apply_event(&2, &1))
  end

  def apply_event(_state, %WorkItemEvent{type: :created, work_item_id: wid, payload: p}) do
    # B1 invariant #9: the Slice-A `facet_text` and `attention` keys may be present
    # in legacy `:created` payloads, but the B1 reducer does NOT project them.
    # Per-viewer state comes only from :attention_set (and B2's :facet_generated).
    %{
      work_item: %{
        id: wid,
        kind: to_atom(get(p, "kind")),
        state: to_atom(get(p, "state")),
        title: get(p, "title"),
        people: get(p, "people") || %{},
        channel_id: get(p, "channel_id"),
        thread_root_message_id: get(p, "thread_root_message_id"),
        card_message_id: nil,
        moved_at: to_dt(get(p, "moved_at"))
      },
      decision: %{
        work_item_id: wid,
        what: get(p, "what"),
        why: get(p, "why"),
        next: get(p, "next")
      },
      facets: %{}
    }
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :state_changed, payload: p}) do
    %{
      state
      | work_item: %{wi | state: to_atom(get(p, "to")), moved_at: to_dt(get(p, "moved_at"))}
    }
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :card_posted, payload: p}) do
    %{state | work_item: %{wi | card_message_id: get(p, "card_message_id")}}
  end

  # Invariant #4 (one reducer, two uses): this clause is called inline by
  # `Sous.set_attention/4` AND by replay. Last-write-wins on the row (spec §5).
  def apply_event(state, %WorkItemEvent{type: :attention_set, payload: p}) do
    facets = Map.get(state, :facets, %{})
    viewer_id = get(p, "viewer_id")
    attention = to_atom(get(p, "attention"))

    new_facet =
      facets
      |> Map.get(viewer_id, %{attention: :watch, facet_text: nil})
      |> Map.put(:attention, attention)

    Map.put(state, :facets, Map.put(facets, viewer_id, new_facet))
  end

  defp get(map, key), do: Map.get(map, key)

  defp to_atom(nil), do: nil
  defp to_atom(v) when is_atom(v), do: v

  defp to_atom(v) when is_binary(v) do
    # WorkItem's module attributes (@kinds, @states) materialize every enum atom
    # this projection round-trips. Ensure it is loaded so String.to_existing_atom
    # never depends on incidental load order — the producer (Sous.open_decision)
    # writes these strings, so the consumer here must be able to read them back
    # regardless of which process runs first. B1: attention atoms are kept alive
    # by @attention_atoms above (Slice-A's @attentions moved off WorkItem).
    _ = Code.ensure_loaded?(Slackex.Sous.WorkItem)
    String.to_existing_atom(v)
  end

  defp to_dt(nil), do: nil
  defp to_dt(%DateTime{} = dt), do: dt

  defp to_dt(v) when is_binary(v) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end
end
