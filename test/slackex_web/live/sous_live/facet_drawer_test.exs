defmodule SlackexWeb.SousLive.FacetDrawerTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Drawer me",
        what: "the what",
        why: "the why",
        next: "the next",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "clicking a card opens the drawer with the atom + a prism per seeded viewer", %{
    conn: conn,
    wi: wi
  } do
    {:ok, lv, _} = live(conn, ~p"/in-service")

    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    html = render(lv)
    assert html =~ "Drawer me"
    assert html =~ "the what"
    # All 7 seeded viewers render as a prism.
    for v <- ~w(CEO CTO EM Product CSM Architect Staff) do
      assert html =~ v, "expected prism for #{v}"
    end
  end

  test "selecting an attention in a prism's 4-pill selector triages that viewer", %{
    conn: conn,
    wi: wi,
    user: u
  } do
    {:ok, lv, _} = live(conn, ~p"/in-service")

    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    # The selector is rendered with 4 pills; selecting :act for the CTO prism
    # emits "triage_attention" with viewer_id=cto, attention=act.
    render_hook(lv, "triage_attention", %{
      "work_item_id" => Integer.to_string(wi.id),
      "viewer_id" => "cto",
      "attention" => "act"
    })

    facet =
      Slackex.Repo.get_by!(Slackex.Sous.WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")

    assert facet.attention == :act
    _ = u
  end
end
