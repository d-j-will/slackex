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
end
