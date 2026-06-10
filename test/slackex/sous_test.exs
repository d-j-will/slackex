defmodule Slackex.SousTest do
  use Slackex.DataCase, async: true

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{Projection, WorkItem, WorkItemEvent}

  import Ecto.Query

  setup do
    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})
    %{user: user, channel: channel}
  end

  describe "open_decision/1" do
    test "creates a :mise decision with a :created event and a Decision", %{user: u, channel: c} do
      assert {:ok, wi} =
               Sous.open_decision(%{
                 channel_id: c.id,
                 thread_root_message_id: nil,
                 actor_id: u.id,
                 title: "Adopt event sourcing",
                 what: "Use an append-only log",
                 why: "Auditability",
                 next: "Spike the reducer",
                 stakeholders: [u.id]
               })

      assert wi.kind == :decision
      assert wi.state == :mise
      assert wi.channel_id == c.id

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert [%{type: :created}] = events

      decision = Repo.get_by!(Slackex.Sous.Decision, work_item_id: wi.id)
      assert decision.what == "Use an append-only log"
    end

    test "the persisted row equals folding its full event log (replay guard, invariant #7)", %{
      user: u,
      channel: c
    } do
      {:ok, wi} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          actor_username: u.username,
          title: "Replayable",
          what: "w",
          why: "y",
          next: "n",
          stakeholders: [u.id]
        })

      {:ok, _moved} = Sous.move(wi.id, :pass, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "ceo", :hidden, u.id)

      persisted = Repo.get!(WorkItem, wi.id) |> Repo.preload(:decision)
      facet_rows = Repo.all(from f in Slackex.Sous.WorkItemFacet, where: f.work_item_id == ^wi.id)
      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)

      assert Enum.map(events, & &1.type) == [
               :created,
               :state_changed,
               :attention_set,
               :attention_set
             ]

      folded = Projection.fold(events)

      for field <- [
            :id,
            :kind,
            :state,
            :title,
            :people,
            :channel_id,
            :thread_root_message_id,
            :card_message_id,
            :moved_at
          ] do
        assert Map.get(folded.work_item, field) == Map.get(persisted, field),
               "field #{field} diverged"
      end

      assert folded.decision.what == persisted.decision.what
      assert folded.decision.why == persisted.decision.why
      assert folded.decision.next == persisted.decision.next

      # Facets: folded.facets must mirror the persisted rows (lazy default = no row).
      persisted_facets = Map.new(facet_rows, fn f -> {f.viewer_id, f.attention} end)
      folded_facets = Map.new(folded.facets, fn {vid, %{attention: a}} -> {vid, a} end)
      assert folded_facets == persisted_facets
    end

    test "rolls back entirely when the decision is invalid", %{user: u, channel: c} do
      assert {:error, _step, _changeset, _} =
               Sous.open_decision(%{
                 channel_id: c.id,
                 actor_id: u.id,
                 title: "No what field",
                 what: nil,
                 stakeholders: []
               })

      assert Repo.aggregate(WorkItem, :count) == 0
      assert Repo.aggregate(WorkItemEvent, :count) == 0
    end
  end

  describe "move/3" do
    setup %{user: u, channel: c} do
      {:ok, wi} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          title: "Movable",
          what: "w",
          stakeholders: []
        })

      %{wi: wi}
    end

    test "moves to a new state and appends a :state_changed event", %{wi: wi, user: u} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      assert {:ok, moved} = Sous.move(wi.id, :pass, u.id)
      assert moved.state == :pass
      assert DateTime.compare(moved.moved_at, wi.moved_at) in [:gt, :eq]

      assert_receive {:work_item_event, :state_changed, %WorkItem{state: :pass}}

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert Enum.map(events, & &1.type) == [:created, :state_changed]
    end

    test "rejects an unknown target state", %{wi: wi, user: u} do
      assert {:error, :invalid_state} = Sous.move(wi.id, :bogus, u.id)
    end

    test "rejects a no-op move to the same state", %{wi: wi, user: u} do
      assert {:error, :no_op} = Sous.move(wi.id, :mise, u.id)
    end
  end

  describe "queries" do
    test "list_in_flight/0 groups work items by state", %{user: u, channel: c} do
      {:ok, a} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          title: "A",
          what: "w",
          stakeholders: []
        })

      {:ok, b} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          title: "B",
          what: "w",
          stakeholders: []
        })

      {:ok, _} = Sous.move(b.id, :pass, u.id)

      grouped = Sous.list_in_flight()
      assert Enum.map(grouped[:mise], & &1.id) == [a.id]
      assert Enum.map(grouped[:pass], & &1.id) == [b.id]
      assert grouped[:order] == []
      assert grouped[:walked] == []
    end
  end
end
