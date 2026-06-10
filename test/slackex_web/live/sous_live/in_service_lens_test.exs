defmodule SlackexWeb.SousLive.InServiceLensTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)

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

  test "the default 'All' lens sorts cards newest-first within a column (N1 regression)", %{
    conn: conn
  } do
    # wi_a (Alpha) was created BEFORE wi_b (Beta) in setup; per spec §7.2 the
    # per-column secondary sort is `inserted_at desc`. Snowflake IDs are
    # time-ordered, so Beta should appear above Alpha in the rendered HTML.
    {:ok, _lv, html} = live(conn, ~p"/in-service")

    {alpha_pos, _} = :binary.match(html, "Alpha")
    {beta_pos, _} = :binary.match(html, "Beta")
    assert beta_pos < alpha_pos, "newer card (Beta) should render before older (Alpha)"
  end

  test "act/know render their CSS treatments and act sorts above watch within a column", %{
    conn: conn,
    user: u,
    wi_a: a,
    wi_b: b
  } do
    # wi_a triaged :act (CTO lens); wi_b stays default :watch.
    {:ok, _} = Sous.set_attention(a.id, "cto", :act, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})
    html = render(lv)

    # :act treatment: accent left-border + "behind" tag (spec §7.2).
    assert html =~ "border-l-4 border-primary"
    assert html =~ "behind"

    # Sort-to-top: Alpha (:act) above Beta (:watch) within :mise.
    {alpha_pos, _} = :binary.match(html, "Alpha")
    {beta_pos, _} = :binary.match(html, "Beta")
    assert alpha_pos < beta_pos, "act card (Alpha) should sort above watch card (Beta)"

    # :know treatment: trigger by triaging wi_b :know and re-render.
    {:ok, _} = Sous.set_attention(b.id, "cto", :know, u.id)
    html2 = render(lv)
    assert html2 =~ "border-dashed"
    assert html2 =~ "opacity-60"
  end
end
