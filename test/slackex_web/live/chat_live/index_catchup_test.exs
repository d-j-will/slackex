defmodule SlackexWeb.ChatLive.IndexCatchupTest do
  use SlackexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  # The real CatchupServer hits Redis for read cursors. We want to exercise the
  # wiring from mount -> Catchup.merge_unread/summary -> flash, so hitting the
  # DB fallback in CatchupServer is fine: it returns cursor=0 for users with no
  # ReadCursor row, which means all channel messages count as unread.

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  describe "reconnect-mount catchup" do
    setup do
      FunWithFlags.enable(:catchup_on_reconnect)
      :ok
    end

    test "flashes a summary and restores unread counts when messages arrived during disconnect",
         %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:subscription, user: other, channel: channel)

      # Simulate 3 messages that arrived while the user was disconnected.
      for n <- 1..3 do
        insert(:message, channel: channel, sender: other, content: "missed #{n}")
      end

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "3 new messages while you were away"
    end

    test "no flash when user is fully caught up", %{conn: conn} do
      user = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "new message"
      refute html =~ "while you were away"
    end

    test "does not flash when :catchup_on_reconnect is disabled", %{conn: conn} do
      FunWithFlags.disable(:catchup_on_reconnect)

      user = insert(:user)
      other = insert(:user)
      channel = insert(:channel)
      insert(:subscription, user: user, channel: channel)
      insert(:subscription, user: other, channel: channel)

      for n <- 1..3 do
        insert(:message, channel: channel, sender: other, content: "missed #{n}")
      end

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "new message"
      refute html =~ "while you were away"
    end
  end
end
