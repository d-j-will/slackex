defmodule Slackex.Sous.SetAttentionTest do
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
        title: "Adopt facets",
        what: "Per-viewer attention",
        stakeholders: []
      })

    %{user: user, channel: channel, wi: wi}
  end

  describe "set_attention/4" do
    test "creates a :attention_set event and upserts a WorkItemFacet row", %{user: u, wi: wi} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      assert {:ok, facet} = Sous.set_attention(wi.id, "cto", :act, u.id)
      assert facet.attention == :act
      assert facet.work_item_id == wi.id
      assert facet.viewer_id == "cto"

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert Enum.map(events, & &1.type) |> Enum.member?(:attention_set)

      assert_receive {:work_item_event, :attention_set,
                      %{work_item_id: id, viewer_id: "cto", attention: :act}}
                     when id == wi.id
    end

    test "is last-write-wins on the row but the log keeps both events", %{user: u, wi: wi} do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "cto", :hidden, u.id)

      facet = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      assert facet.attention == :hidden

      events =
        Repo.all(
          from e in WorkItemEvent,
            where: e.work_item_id == ^wi.id and e.type == :attention_set,
            order_by: e.id
        )

      assert length(events) == 2
    end

    test "rejects an unknown viewer", %{user: u, wi: wi} do
      assert {:error, :invalid_viewer} = Sous.set_attention(wi.id, "no_such_role", :act, u.id)
    end

    test "rejects an unknown attention", %{user: u, wi: wi} do
      assert {:error, :invalid_attention} = Sous.set_attention(wi.id, "cto", :bogus, u.id)
    end

    test "rejects an unknown work item", %{user: u} do
      assert {:error, :invalid_work_item} = Sous.set_attention(999_999_999_999, "cto", :act, u.id)
    end
  end

  describe "facets_for_viewer/1" do
    test "returns %{work_item_id => attention} for the viewer; missing rows = nothing", %{
      user: u,
      wi: wi
    } do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "ceo", :know, u.id)

      assert Sous.facets_for_viewer("cto") == %{wi.id => :act}
      assert Sous.facets_for_viewer("ceo") == %{wi.id => :know}
      assert Sous.facets_for_viewer("em") == %{}
    end
  end
end
