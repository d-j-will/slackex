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

  alias Ecto.Multi
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Messaging
  alias Slackex.Repo
  alias Slackex.Sous.{Decision, Projection, WorkItem, WorkItemEvent}

  @pubsub Slackex.PubSub
  @work_items_topic "sous:work_items"

  @doc "Workspace-wide board topic."
  def work_items_topic, do: @work_items_topic

  @doc "Channel-scoped decision-card upgrade topic."
  def cards_topic(channel_id), do: "sous:cards:channel:#{channel_id}"

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
      "facet_text" => attrs[:title],
      # Slice A has no viewer model, so attention is a single stored value. A
      # freshly-made decision demands attention → :act (accent edge + "behind"),
      # so the board shows a real treatment from day one. Attention stays :act for
      # Slice A (no attention control — deferred to Slice B).
      "attention" => "act",
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

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.update(
      :work_item,
      WorkItem.changeset(wi, %{
        state: projected.work_item.state,
        moved_at: projected.work_item.moved_at
      })
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

  defp card_fallback_text(%WorkItem{title: title}), do: "Decision: #{title}"

  defp wi_to_attrs(%WorkItem{} = wi) do
    %{
      id: wi.id,
      kind: wi.kind,
      state: wi.state,
      title: wi.title,
      facet_text: wi.facet_text,
      attention: wi.attention,
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
