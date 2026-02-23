defmodule SlackexWeb.ChatLive.IndexTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Notifications.OnlineTracker

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ets.delete_all_objects(:slackex_message_cache)
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, user: user}
  end

  describe "mount" do
    test "marks user online when connected", %{conn: conn, user: user} do
      {:ok, _view, _html} = live(conn, ~p"/chat")
      assert OnlineTracker.online?(user.id)
    end
  end

  describe "heartbeat" do
    test "refresh heartbeat keeps user online and reschedules", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      assert OnlineTracker.online?(user.id)

      send(view.pid, :online_heartbeat)
      # render/1 waits for the next render, flushing the message
      render(view)

      assert OnlineTracker.online?(user.id)
    end
  end

  describe "terminate" do
    test "marks user offline when view terminates", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      assert OnlineTracker.online?(user.id)

      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      refute OnlineTracker.online?(user.id)
    end
  end
end
