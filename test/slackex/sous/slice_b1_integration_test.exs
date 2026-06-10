defmodule Slackex.Sous.SliceB1IntegrationTest do
  @moduledoc """
  Triage → broadcast → board reshape, real PubSub, no faked upstream.

  Two boards subscribed; one calls Sous.set_attention/4; the other receives
  the broadcast and reshapes.
  """

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
        title: "Bridge",
        what: "w",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "triage propagates: a second connected board reshapes when an :attention_set broadcast lands",
       %{conn: conn, user: u, wi: wi} do
    {:ok, board, _} = live(conn, ~p"/in-service")
    render_click(board, "select_viewer", %{"id" => "cto"})
    assert render(board) =~ "Bridge"

    # Producer: a different process calls set_attention/4. The board (subscribed
    # to "sous:work_items") must receive the :attention_set broadcast, re-pull
    # facets_for_viewer("cto"), and reshape — "Bridge" becomes :hidden.
    {:ok, _} = Sous.set_attention(wi.id, "cto", :hidden, u.id)

    assert render(board) =~ "+1 not at your altitude"
    refute render(board) =~ "Bridge"
  end
end
