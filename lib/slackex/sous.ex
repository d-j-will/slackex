defmodule Slackex.Sous do
  @moduledoc """
  The Sous work-item event stream (Slice A).

  All mutations flow through this module's command functions (single write
  path, invariant #1). Each writes a `WorkItemEvent` and applies the projection
  via `Slackex.Sous.Projection` in the SAME transaction (invariant #2). Event
  payloads are self-describing with string keys (invariant #3) so the inline
  projection here and a future replay projection agree.

  Topics:
    * "sous:work_items"            — workspace-wide; the In Service board.
    * "sous:cards:channel:\#{id}"  — channel-scoped; chat decision-card upgrade.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Messaging
  alias Slackex.Repo
  alias Slackex.Sous.{Decision, Projection, Viewer, WorkItem, WorkItemEvent, WorkItemFacet}

  @pubsub Slackex.PubSub
  @work_items_topic "sous:work_items"

  @doc "Workspace-wide board topic."
  def work_items_topic, do: @work_items_topic

  @doc "Channel-scoped decision-card upgrade topic."
  def cards_topic(channel_id), do: "sous:cards:channel:#{channel_id}"

  @doc """
  Per-work-item B2 facet topic. Low fan-out: subscribers are the open Drawer
  (and optionally the board for that work item). Mirrors the `cards_topic/1`
  pattern but scoped to the work item, not the channel.
  """
  def facets_topic(work_item_id), do: "sous:facets:#{work_item_id}"

  @doc """
  Creates a `:decision` work item in state `:mise` from a chat context.

  Required attrs: `:channel_id`, `:actor_id`, `:title`, `:what`.
  Optional: `:why`, `:next`, `:thread_root_message_id`, `:stakeholders` (list of user ids),
  `:actor_username` (snapshotted as the DRI name for the chat card).
  """
  def open_decision(attrs) do
    id = Snowflake.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    lead = attrs[:actor_id]
    stakeholders = attrs[:stakeholders] || []

    payload = %{
      "kind" => "decision",
      "title" => attrs[:title],
      "state" => "mise",
      # B1 (invariant #9): per-viewer attention lives on work_item_facets and is
      # set via :attention_set events. The Slice-A single-viewer facet/attention
      # keys are no longer written into new :created payloads.
      # DRI name is snapshotted into the event (self-describing) so the card
      # renders with no render-time user lookup.
      "people" => %{
        "lead" => lead,
        "lead_name" => attrs[:actor_username],
        "supporting" => [],
        "watching" => [],
        "stakeholders" => stakeholders
      },
      "what" => attrs[:what],
      "why" => attrs[:why],
      "next" => attrs[:next],
      "channel_id" => attrs[:channel_id],
      "thread_root_message_id" => attrs[:thread_root_message_id],
      "moved_at" => DateTime.to_iso8601(now)
    }

    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: id,
      type: :created,
      payload: payload,
      actor_user_id: lead
    }

    projected = Projection.apply_event(Projection.initial(), event)

    Multi.new()
    |> Multi.insert(
      :work_item,
      WorkItem.changeset(%WorkItem{}, Map.put(projected.work_item, :id, id))
    )
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.insert(:decision, Decision.changeset(%Decision{}, projected.decision))
    |> Repo.transaction()
    |> case do
      {:ok, %{work_item: work_item}} ->
        broadcast_work_item(:created, work_item)
        {:ok, work_item}

      {:error, step, changeset, _changes} ->
        {:error, step, changeset, %{}}
    end
  end

  @doc """
  Posts the decision card to the work item's channel via the existing messaging
  facade, then records the linkage as a `:card_posted` event (ADR-002).

  Returns `{:ok, work_item}` with `card_message_id` set, or `{:error, reason}`.
  On failure the work item is left intact (no card); the caller logs it.
  """
  def post_decision_card(%WorkItem{} = wi, actor_id) do
    with {:ok, msg} <- Messaging.send_message(wi.channel_id, actor_id, card_fallback_text(wi)) do
      event = %WorkItemEvent{
        id: Snowflake.generate(),
        work_item_id: wi.id,
        type: :card_posted,
        payload: %{"card_message_id" => msg.id},
        actor_user_id: actor_id
      }

      projected = Projection.apply_event(%{work_item: wi_to_attrs(wi), decision: nil}, event)

      Multi.new()
      |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
      |> Multi.update(
        :work_item,
        WorkItem.changeset(wi, %{card_message_id: projected.work_item.card_message_id})
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{work_item: updated}} ->
          broadcast_work_item(:card_posted, updated)

          _result =
            Phoenix.PubSub.broadcast(
              @pubsub,
              cards_topic(wi.channel_id),
              {:decision_card, msg.id, updated}
            )

          {:ok, updated}

        {:error, _step, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Moves a work item to `to_state` (one of `WorkItem.states/0`), appending a
  `:state_changed` event. Returns `{:ok, work_item}` or `{:error, reason}`.
  """
  def move(work_item_id, to_state, actor_id) do
    if to_state in WorkItem.states() do
      wi = Repo.get!(WorkItem, work_item_id)

      if wi.state == to_state do
        {:error, :no_op}
      else
        do_move(wi, to_state, actor_id)
      end
    else
      {:error, :invalid_state}
    end
  end

  defp do_move(%WorkItem{} = wi, to_state, actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: wi.id,
      type: :state_changed,
      payload: %{
        "from" => Atom.to_string(wi.state),
        "to" => Atom.to_string(to_state),
        "moved_at" => DateTime.to_iso8601(now)
      },
      actor_user_id: actor_id
    }

    projected = Projection.apply_event(%{work_item: wi_to_attrs(wi), decision: nil}, event)

    now_stale = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.update(
      :work_item,
      WorkItem.changeset(wi, %{
        state: projected.work_item.state,
        moved_at: projected.work_item.moved_at
      })
    )
    # Invariant #14: :state_changed marks B2 facet rows stale; it does NOT enqueue.
    # The next drawer-open is the only trigger that re-generates.
    |> Multi.update_all(
      :invalidate_facets,
      from(f in WorkItemFacet, where: f.work_item_id == ^wi.id),
      set: [facet_stale_at: now_stale]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{work_item: updated}} ->
        broadcast_work_item(:state_changed, updated)
        {:ok, updated}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Sets the attention of `viewer_id` for `work_item_id` to `attention`. Appends a
  `:attention_set` event and upserts the `WorkItemFacet` row (last-write-wins).

  `attention` must be in `WorkItemFacet.attentions/0`; `viewer_id` must reference
  an existing `Viewer` row (immutable in B1, invariant #11).
  """
  def set_attention(work_item_id, viewer_id, attention, actor_id) do
    cond do
      attention not in WorkItemFacet.attentions() ->
        {:error, :invalid_attention}

      not Repo.exists?(from v in Viewer, where: v.id == ^viewer_id) ->
        {:error, :invalid_viewer}

      not Repo.exists?(from w in WorkItem, where: w.id == ^work_item_id) ->
        {:error, :invalid_work_item}

      true ->
        do_set_attention(work_item_id, viewer_id, attention, actor_id)
    end
  end

  @doc """
  Per-viewer attention map for the In Service board.
  Returns `%{work_item_id => attention_atom}` for rows where this viewer has
  been triaged; absence = default `:watch` (the caller resolves).
  """
  def facets_for_viewer(viewer_id) when is_binary(viewer_id) do
    from(f in WorkItemFacet,
      where: f.viewer_id == ^viewer_id,
      select: {f.work_item_id, f.attention}
    )
    |> Repo.all()
    |> Map.new()
  end

  def facets_for_viewer(nil), do: %{}

  @doc """
  B2: MapSet of `work_item_id` for which `viewer_id` has a row whose
  `facet_stale_at` is set (board-card subtle dot indicator, spec §7.3).
  Rows that don't exist (`:never_generated` for the viewer) are NOT included —
  they are the common case (no row yet) and would surface the indicator on
  every card; spec wording reads "stale or never-generated" but cost-wise we
  scope to stale here (the more meaningful signal). If we want never_generated
  later, we'd need a separate query against the viewers table.
  """
  def stale_facets_for_viewer(viewer_id) when is_binary(viewer_id) do
    Repo.all(
      from f in WorkItemFacet,
        where: f.viewer_id == ^viewer_id and not is_nil(f.facet_stale_at),
        select: f.work_item_id
    )
    |> MapSet.new()
  end

  def stale_facets_for_viewer(nil), do: MapSet.new()

  defp do_set_attention(work_item_id, viewer_id, attention, actor_id) do
    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: work_item_id,
      type: :attention_set,
      payload: %{
        "viewer_id" => viewer_id,
        "attention" => Atom.to_string(attention),
        "actor_user_id" => actor_id
      },
      actor_user_id: actor_id
    }

    # Invariant #4 (one reducer, two uses): derive the row attrs through the
    # same Projection.apply_event the replay path uses.
    projected = Projection.apply_event(%{facets: %{}}, event)

    facet_attrs =
      projected.facets[viewer_id]
      |> Map.put(:work_item_id, work_item_id)
      |> Map.put(:viewer_id, viewer_id)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.insert(
      :facet,
      WorkItemFacet.changeset(%WorkItemFacet{}, facet_attrs),
      on_conflict: {:replace, [:attention, :updated_at]},
      conflict_target: [:work_item_id, :viewer_id]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{facet: facet}} ->
        _ =
          Phoenix.PubSub.broadcast(
            @pubsub,
            @work_items_topic,
            {:work_item_event, :attention_set,
             %{work_item_id: work_item_id, viewer_id: viewer_id, attention: attention}}
          )

        {:ok, facet}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc "All in-flight work items grouped by state. Every state key is present (possibly empty)."
  def list_in_flight do
    base = for s <- WorkItem.states(), into: %{}, do: {s, []}

    WorkItem
    |> order_by(desc: :inserted_at)
    |> preload(:decision)
    |> Repo.all()
    |> Enum.group_by(& &1.state)
    |> then(&Map.merge(base, &1))
  end

  @doc """
  Returns all `Viewer` rows in switcher (position asc) order. B-later role-mgmt
  UI may filter; B2 returns everyone.
  """
  def list_viewers do
    Repo.all(Viewer.order_by_position())
  end

  @doc "Fetches a viewer by id. Returns the struct or `nil`. Used by FacetWorker."
  def get_viewer(viewer_id) when is_binary(viewer_id), do: Repo.get(Viewer, viewer_id)
  def get_viewer(_), do: nil

  @doc "Fetches a work item by id. Returns the struct or `nil`. Used by FacetWorker."
  def get_work_item(work_item_id) when is_integer(work_item_id),
    do: Repo.get(WorkItem, work_item_id)

  def get_work_item(_), do: nil

  @doc """
  Fetches the `Decision` row for a work item by `work_item_id` (Decision's PK).
  Returns the struct or `nil`. Used by FacetWorker.
  """
  def get_decision(work_item_id) when is_integer(work_item_id),
    do: Repo.get_by(Decision, work_item_id: work_item_id)

  def get_decision(_), do: nil

  @doc """
  B2 `state_version/1`: count of `:state_changed` events for the work item.

  Read **once at enqueue time** by the Drawer, embedded in `FacetWorker` job args,
  and copied verbatim into the `:facet_generated` event payload. Never re-queried
  by the worker — the Oban uniqueness key is hashed over args at enqueue, so
  re-querying would silently break dedup (spec §3 + invariant referenced in §4).
  """
  @spec state_version(integer()) :: integer()
  def state_version(work_item_id) when is_integer(work_item_id) do
    Repo.aggregate(
      from(e in WorkItemEvent,
        where: e.work_item_id == ^work_item_id and e.type == :state_changed
      ),
      :count
    )
  end

  @doc """
  All `WorkItemFacet` rows for a work item. The Drawer composes pill states
  via `WorkItemFacet.state/3`.
  """
  def facets_for_work_item(work_item_id) when is_integer(work_item_id) do
    Repo.all(from f in WorkItemFacet, where: f.work_item_id == ^work_item_id)
  end

  @doc """
  Sole writer of `facet_text` (B2 invariant #12 / Slice-A invariant #5 extended).

  `attrs` is map-shaped (per Ecto changeset convention, survives field additions):
    * `:facet_text` (string, required)
    * `:model` (string)
    * `:prompt_version` (integer)
    * `:state_version` (integer — copied verbatim into the event payload; do NOT
       re-query here; the FacetWorker passes it through from `job.args`).

  Atomic Multi:
    1. Append `:facet_generated` event with full payload.
    2. Upsert the `WorkItemFacet` row (lazy `:watch` default for the attention
       field if no row existed — invariant #16; clears `facet_stale_at`).
    3. Broadcast `{:sous, :facet_generated, work_item_id, viewer_id}` on the
       per-work-item facets topic on success.
  """
  def set_facet_text(work_item_id, viewer_id, attrs)
      when is_integer(work_item_id) and is_binary(viewer_id) and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    event_payload = %{
      "viewer_id" => viewer_id,
      "facet_text" => Map.fetch!(attrs, :facet_text),
      "model" => Map.get(attrs, :model),
      "prompt_version" => Map.get(attrs, :prompt_version),
      "generated_at" => DateTime.to_iso8601(now),
      "state_version" => Map.fetch!(attrs, :state_version)
    }

    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: work_item_id,
      type: :facet_generated,
      payload: event_payload,
      actor_user_id: nil
    }

    # Invariant #4 — derive the row through the same Projection.apply_event the
    # replay path uses. The lazy default `:watch` is applied here for rows that
    # never had attention set (invariant #16).
    projected = Projection.apply_event(%{facets: %{}}, event)

    facet_attrs =
      projected.facets[viewer_id]
      |> Map.put(:work_item_id, work_item_id)
      |> Map.put(:viewer_id, viewer_id)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.insert(
      :facet,
      WorkItemFacet.changeset(%WorkItemFacet{}, facet_attrs),
      on_conflict:
        {:replace,
         [
           :facet_text,
           :facet_model,
           :facet_prompt_version,
           :facet_generated_at,
           :facet_stale_at,
           :updated_at
         ]},
      conflict_target: [:work_item_id, :viewer_id]
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} ->
        # Re-fetch so the returned struct reflects the merged row (the upsert
        # `on_conflict: {:replace, [...B2 fields...]}` preserves the pre-existing
        # `:attention` value, which the changeset-built struct doesn't know about).
        facet = Repo.get_by!(WorkItemFacet, work_item_id: work_item_id, viewer_id: viewer_id)

        _ =
          Phoenix.PubSub.broadcast(
            @pubsub,
            facets_topic(work_item_id),
            {:sous, :facet_generated, work_item_id, viewer_id}
          )

        {:ok, facet}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc "Map of `card_message_id => work_item` (with decision preloaded) for a channel."
  def card_messages_for_channel(channel_id) do
    WorkItem
    |> where([w], w.channel_id == ^channel_id and not is_nil(w.card_message_id))
    |> preload(:decision)
    |> Repo.all()
    |> Map.new(fn wi -> {wi.card_message_id, wi} end)
  end

  defp card_fallback_text(%WorkItem{title: title}), do: "Decision: #{title}"

  defp wi_to_attrs(%WorkItem{} = wi) do
    %{
      id: wi.id,
      kind: wi.kind,
      state: wi.state,
      title: wi.title,
      people: wi.people,
      channel_id: wi.channel_id,
      thread_root_message_id: wi.thread_root_message_id,
      card_message_id: wi.card_message_id,
      moved_at: wi.moved_at
    }
  end

  defp broadcast_work_item(event_type, work_item) do
    _result =
      Phoenix.PubSub.broadcast(
        @pubsub,
        @work_items_topic,
        {:work_item_event, event_type, work_item}
      )

    :ok
  end
end
