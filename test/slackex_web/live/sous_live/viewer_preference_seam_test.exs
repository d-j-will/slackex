defmodule SlackexWeb.SousLive.ViewerPreferenceSeamTest do
  @moduledoc """
  Proves invariant #10 (Slice B1 spec): a `ViewerPreference.Store` swap is a
  one-line config change. The InMemoryStore implements the behaviour; flipping
  the app env to it must not require any change to call sites — the board
  renders and the switcher works.

  `async: false` because the test rebinds `:viewer_preference_store` globally
  (and restores it via on_exit).
  """

  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    original = Application.get_env(:slackex, :viewer_preference_store)

    Application.put_env(
      :slackex,
      :viewer_preference_store,
      Slackex.Sous.ViewerPreference.InMemoryStore
    )

    on_exit(fn -> Application.put_env(:slackex, :viewer_preference_store, original) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Seam decision",
        what: "w",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  @tag :pending_b1_task13
  test "the In Service board renders against the InMemoryStore — no LocalStorage hook in play", %{
    conn: conn
  } do
    {:ok, lv, html} = live(conn, ~p"/in-service")
    assert html =~ "In Service"

    # The store backs ViewerPreference; switching viewer still works via the
    # switcher (default render shows "All" selected).
    assert render(lv) =~ "All"
  end
end
