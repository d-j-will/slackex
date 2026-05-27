defmodule Slackex.SousTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous
  alias Slackex.Sous.{WorkItem, WorkItemEvent, Projection}
  alias Slackex.Repo

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
      assert wi.attention == :act
      assert wi.facet_text == "Adopt event sourcing"
      assert wi.channel_id == c.id

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert [%{type: :created}] = events

      decision = Repo.get_by!(Slackex.Sous.Decision, work_item_id: wi.id)
      assert decision.what == "Use an append-only log"
    end

    test "the persisted row equals folding its event log (replay guard, invariant #7)", %{
      user: u,
      channel: c
    } do
      {:ok, wi} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          title: "Replayable",
          what: "w",
          stakeholders: []
        })

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      folded = Projection.fold(events).work_item

      assert folded.state == wi.state
      assert folded.title == wi.title
      assert folded.kind == wi.kind
      assert folded.attention == wi.attention
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
