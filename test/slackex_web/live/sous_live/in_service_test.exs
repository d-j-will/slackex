defmodule SlackexWeb.SousLive.InServiceTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "renders the four columns with an existing decision in Mise", %{
    conn: conn,
    alice: a,
    channel: c
  } do
    {:ok, _wi} =
      Sous.open_decision(%{
        channel_id: c.id,
        actor_id: a.id,
        title: "Board Item",
        what: "w",
        stakeholders: []
      })

    {:ok, _lv, html} = live(conn, ~p"/in-service")

    assert html =~ "Order"
    assert html =~ "Mise"
    assert html =~ "Pass"
    assert html =~ "Walked"
    assert html =~ "Board Item"
  end

  test "moving a card via a button updates the board", %{conn: conn, alice: a, channel: c} do
    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: c.id,
        actor_id: a.id,
        title: "Mover",
        what: "w",
        stakeholders: []
      })

    {:ok, lv, _html} = live(conn, ~p"/in-service")

    lv |> element(~s{button[phx-value-id="#{wi.id}"][phx-value-to="pass"]}) |> render_click()

    assert Sous.list_in_flight()[:pass] |> Enum.map(& &1.id) == [wi.id]
  end

  test "redirects when the :sous flag is off", %{conn: conn} do
    FunWithFlags.disable(:sous)

    assert {:error, {:redirect, %{to: "/chat"}}} = live(conn, ~p"/in-service")
  end

  # Regression: the :chat layout mounts shared JS hooks (Analytics, AppBadge) that
  # push analytics:* / page:* events to EVERY LiveView in the session. Before these
  # were centralized in SlackexWeb.AnalyticsTracker, the board had no matching
  # handle_event clause and crashed (FunctionClauseError) on the first click. JS
  # hooks don't run in LiveView tests, so we push the events directly.
  test "handles shared :chat-layout chrome events without crashing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/in-service")

    assert render_hook(lv, "analytics:click", %{"target" => "card"})
    assert render_hook(lv, "page:visible", %{})
    assert render_hook(lv, "page:hidden", %{})

    # Still alive and rendering after the chrome events.
    assert render(lv) =~ "In Service"
  end
end
