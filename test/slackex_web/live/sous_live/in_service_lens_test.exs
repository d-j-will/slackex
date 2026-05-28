defmodule SlackexWeb.SousLive.InServiceLensTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, a} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Alpha",
        what: "w",
        stakeholders: []
      })

    {:ok, b} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Beta",
        what: "w",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi_a: a, wi_b: b}
  end

  test "default lens (null / 'All') resolves every card to :watch with no errors (invariant #8 behavioural)",
       %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/in-service")
    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "All"
  end

  test "selecting a viewer reshapes the board by that viewer's attentions", %{
    conn: conn,
    user: u,
    wi_a: a,
    wi_b: b
  } do
    {:ok, _} = Sous.set_attention(a.id, "cto", :act, u.id)
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})
    html = render(lv)

    # :act — visible
    assert html =~ "Alpha"
    # :hidden — not rendered
    refute html =~ "Beta"
    assert html =~ "+1 not at your altitude"
  end

  test "'+N not at your altitude' toggle reveals hidden cards (session-only assign)", %{
    conn: conn,
    user: u,
    wi_a: _a,
    wi_b: b
  } do
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})

    refute render(lv) =~ "Beta"
    render_click(lv, "toggle_hidden", %{"column" => "mise"})
    assert render(lv) =~ "Beta"
  end

  test "switching back to 'All' restores the Slice-A shared shape", %{
    conn: conn,
    user: u,
    wi_a: a,
    wi_b: b
  } do
    {:ok, _} = Sous.set_attention(a.id, "cto", :act, u.id)
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})
    render_click(lv, "select_viewer", %{"id" => ""})

    html = render(lv)
    assert html =~ "Alpha"
    assert html =~ "Beta"
  end
end
