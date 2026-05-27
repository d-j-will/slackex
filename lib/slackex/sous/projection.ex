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

  @type state :: %{work_item: map() | nil, decision: map() | nil}

  @spec initial() :: state()
  def initial, do: %{work_item: nil, decision: nil}

  def fold(events) when is_list(events) do
    Enum.reduce(events, initial(), &apply_event(&2, &1))
  end

  def apply_event(_state, %WorkItemEvent{type: :created, work_item_id: wid, payload: p}) do
    %{
      work_item: %{
        id: wid,
        kind: to_atom(get(p, "kind")),
        state: to_atom(get(p, "state")),
        title: get(p, "title"),
        facet_text: get(p, "facet_text"),
        attention: to_atom(get(p, "attention") || "watch"),
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
      }
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

  defp get(map, key), do: Map.get(map, key)

  defp to_atom(nil), do: nil
  defp to_atom(v) when is_atom(v), do: v

  defp to_atom(v) when is_binary(v) do
    # WorkItem's module attributes (@kinds, @states, @attentions) materialize
    # every enum atom this projection round-trips. Ensure it is loaded so
    # String.to_existing_atom never depends on incidental load order — the
    # producer (Sous.open_decision) writes these strings, so the consumer here
    # must be able to read them back regardless of which process runs first.
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
