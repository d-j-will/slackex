defmodule SlackexWeb.SousLive.FacetDrawerTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)

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

  # Helpers for dismiss tests
  #
  # The three dismiss surfaces (X, backdrop, Escape) all send their events to the
  # FacetDrawerComponent (phx-target={@myself}). The component replies synchronously,
  # but it bridges to the parent LiveView via `send(self(), :close_facet_drawer)`.
  # Phoenix.LiveViewTest returns from `render_click` after the component reply —
  # before the parent has had a chance to process that handle_info. We flush the
  # parent's message queue by calling a synchronous parent-level event
  # (viewer_pref:loaded), then assert on the LV assigns directly.
  defp flush_lv(lv), do: render_hook(lv, "viewer_pref:loaded", %{"viewer_id" => nil})

  test "drawer closes via the X (close) button", %{conn: conn, wi: wi} do
    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()
    assert render(lv) =~ "Drawer me"

    lv |> element(~s{#facet-drawer button[aria-label="Close"]}) |> render_click()
    flush_lv(lv)
    assert :sys.get_state(lv.pid).socket.assigns.drawer_work_item == nil
  end

  test "drawer closes via backdrop click", %{conn: conn, wi: wi} do
    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()
    assert render(lv) =~ "Drawer me"

    # The backdrop is the overlay inside #facet-drawer with phx-click="close_drawer".
    lv
    |> element(~s{#facet-drawer [phx-click="close_drawer"][class*="bg-black"]})
    |> render_click()

    flush_lv(lv)
    assert :sys.get_state(lv.pid).socket.assigns.drawer_work_item == nil
  end

  test "drawer closes on Escape keydown", %{conn: conn, wi: wi} do
    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()
    assert render(lv) =~ "Drawer me"

    # phx-window-keydown="close_drawer" phx-key="Escape" is on the drawer root.
    lv |> element("#facet-drawer") |> render_keydown(%{"key" => "Escape"})
    flush_lv(lv)
    assert :sys.get_state(lv.pid).socket.assigns.drawer_work_item == nil
  end

  test "selecting an attention pill via direct click (not render_hook) triages that viewer", %{
    conn: conn,
    wi: wi
  } do
    {:ok, lv, _} = live(conn, ~p"/in-service")
    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    # Click the actual "act" pill in the CTO prism — exercises the rendered
    # button's phx-click + phx-value-* attributes, not the test-shortcut hook
    # (closes reviewer N3). The component bridges to the parent LV via
    # handle_info({:triage_attention, ...}), so we flush the LV queue first.
    lv
    |> element(~s{[data-prism="cto"] button[phx-value-attention="act"]})
    |> render_click()

    flush_lv(lv)

    facet =
      Slackex.Repo.get_by!(Slackex.Sous.WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")

    assert facet.attention == :act
  end
end
