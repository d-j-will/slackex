defmodule Slackex.Sous.SetFacetTextTest do
  @moduledoc """
  Sous context surface for B2: state_version/1, set_facet_text/3,
  invalidate-on-move (invariant #14). Mirrors the set_attention_test.exs style.
  """

  use Slackex.DataCase, async: true

  import Ecto.Query

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{WorkItemEvent, WorkItemFacet}

  setup do
    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "B2 surface",
        what: "facet text",
        stakeholders: []
      })

    %{user: user, wi: wi}
  end

  describe "state_version/1" do
    test "is 0 for a fresh work item", %{wi: wi} do
      assert Sous.state_version(wi.id) == 0
    end

    test "increments by 1 for each move/3", %{user: u, wi: wi} do
      {:ok, _} = Sous.move(wi.id, :order, u.id)
      assert Sous.state_version(wi.id) == 1
      {:ok, _} = Sous.move(wi.id, :pass, u.id)
      assert Sous.state_version(wi.id) == 2
    end
  end

  describe "set_facet_text/3 (sole writer of facet_text)" do
    test "atomically writes the event and upserts a row with lazy :watch", %{wi: wi} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.facets_topic(wi.id))

      attrs = %{
        facet_text: "cto-prism",
        model: "stub",
        prompt_version: 1,
        state_version: 0
      }

      assert {:ok, facet} = Sous.set_facet_text(wi.id, "cto", attrs)
      assert facet.facet_text == "cto-prism"
      assert facet.facet_model == "stub"
      assert facet.facet_prompt_version == 1
      assert facet.facet_stale_at == nil
      # Lazy default — viewer had no prior attention row.
      assert facet.attention == :watch

      assert_receive {:sous, :facet_generated, wid, "cto"} when wid == wi.id

      events =
        Repo.all(
          from e in WorkItemEvent, where: e.work_item_id == ^wi.id and e.type == :facet_generated
        )

      assert length(events) == 1
      assert hd(events).payload["facet_text"] == "cto-prism"
      assert hd(events).payload["state_version"] == 0
    end

    test "preserves attention when row already exists", %{user: u, wi: wi} do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)

      {:ok, facet} =
        Sous.set_facet_text(wi.id, "cto", %{
          facet_text: "t",
          model: "stub",
          prompt_version: 1,
          state_version: 0
        })

      assert facet.attention == :act
      assert facet.facet_text == "t"
    end

    test "clears facet_stale_at on an already-stale row", %{user: u, wi: wi} do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      # Mark stale via the move-invalidation path.
      {:ok, _} = Sous.move(wi.id, :order, u.id)

      row_before = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      refute is_nil(row_before.facet_stale_at)

      {:ok, facet} =
        Sous.set_facet_text(wi.id, "cto", %{
          facet_text: "t",
          model: "stub",
          prompt_version: 1,
          state_version: 1
        })

      assert facet.facet_stale_at == nil
    end

    test "writes state_version from attrs unchanged (worker contract)", %{user: u, wi: wi} do
      # Pretend the worker was enqueued at state_version 0 but by the time it
      # runs, the work item has moved (state_version is now 1). The worker MUST
      # pass through the args value (0); set_facet_text must persist it as-is.
      {:ok, _} = Sous.move(wi.id, :order, u.id)
      assert Sous.state_version(wi.id) == 1

      {:ok, _facet} =
        Sous.set_facet_text(wi.id, "cto", %{
          facet_text: "t",
          model: "stub",
          prompt_version: 1,
          state_version: 0
        })

      event =
        Repo.one!(
          from e in WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :facet_generated
        )

      assert event.payload["state_version"] == 0
    end
  end

  describe "Sous.move/3 invalidates facets without enqueueing (invariant #14)" do
    test "marks facet_stale_at on existing rows; non-existent rows stay absent", %{
      user: u,
      wi: wi
    } do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "ceo", :watch, u.id)

      {:ok, _} = Sous.move(wi.id, :order, u.id)

      cto = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      ceo = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "ceo")

      assert %DateTime{} = cto.facet_stale_at
      assert %DateTime{} = ceo.facet_stale_at

      # Other viewers have no row yet (lazy invariant #8 stands).
      em = Repo.get_by(WorkItemFacet, work_item_id: wi.id, viewer_id: "em")
      assert is_nil(em)
    end
  end

  describe "accessors" do
    test "list_viewers/0 returns the seeded viewers in position order" do
      viewers = Sous.list_viewers()
      refute viewers == []
      assert hd(viewers).id == "ceo"
    end

    test "get_viewer/1 returns the viewer struct or nil" do
      assert v = Sous.get_viewer("cto")
      assert v.name == "CTO"
      assert Sous.get_viewer("no-such-viewer") == nil
      assert Sous.get_viewer(nil) == nil
    end

    test "get_work_item/1 returns the work item or nil", %{wi: wi} do
      assert %{} = Sous.get_work_item(wi.id)
      assert Sous.get_work_item(0) == nil
    end

    test "get_decision/1 returns the decision keyed by work_item_id", %{wi: wi} do
      assert d = Sous.get_decision(wi.id)
      assert d.what == "facet text"
      assert Sous.get_decision(0) == nil
    end

    test "facets_for_work_item/1 returns the WorkItemFacet rows for the work item", %{
      user: u,
      wi: wi
    } do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      rows = Sous.facets_for_work_item(wi.id)
      assert [%WorkItemFacet{viewer_id: "cto"}] = rows
    end
  end
end
