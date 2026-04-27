defmodule SlackexWeb.ChatLive.ActiveTrackerVisibilityTest do
  use SlackexWeb.ConnCase
  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  alias Slackex.Notifications.ActiveTracker

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  test "page:hidden marker is not overridden by the active_heartbeat tick", %{conn: conn} do
    user = insert(:user)
    channel = insert(:channel)
    insert(:subscription, user: user, channel: channel)

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/chat")

    assert ActiveTracker.active?(user.id)

    render_hook(view, "page:hidden", %{})
    refute ActiveTracker.active?(user.id)

    send(view.pid, :active_heartbeat)
    Process.sleep(50)
    refute ActiveTracker.active?(user.id)
  end
end
