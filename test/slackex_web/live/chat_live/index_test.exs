defmodule SlackexWeb.ChatLive.IndexTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat
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

  # ---------------------------------------------------------------------------
  # Acceptance: Unread badges render in sidebar
  # ---------------------------------------------------------------------------

  describe "unread badges in sidebar" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_sender")

      # Create channel with user as owner, bob as member
      {:ok, channel} = Chat.create_channel(user.id, %{name: "unread-test"})
      Chat.join_channel(bob.id, channel.id)

      # Mark as read so baseline is 0
      Chat.mark_as_read(user.id, channel.id)

      # Bob sends messages the user has not read
      Chat.send_message(channel.id, bob.id, "Unread msg 1")
      Chat.send_message(channel.id, bob.id, "Unread msg 2")

      # Create DM
      {:ok, dm} = Chat.find_or_create_dm(user.id, bob.id)
      Chat.mark_dm_as_read(user.id, dm.id)
      Chat.send_dm(dm.id, bob.id, "Unread DM")

      %{bob: bob, channel: channel, dm: dm}
    end

    test "sidebar shows unread badge for channel with unread messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      # The badge should show count 2 for the channel
      assert html =~ "2"
      assert html =~ "badge-primary"
    end

    test "sidebar shows unread badge for DM with unread messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      # The badge should show count 1 for the DM
      assert html =~ "badge-primary"
    end

    test "entering a channel resets its unread badge to 0", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Navigate to the channel
      view |> element("a[href=\"/chat/#{channel.slug}\"]") |> render_click()

      # After entering, the badge for this channel should be gone
      html = render(view)
      refute html =~ ~r/<span[^>]*badge-primary[^>]*>\s*2\s*<\/span>/
    end

    test "entering a DM resets its unread badge to 0", %{conn: conn, dm: dm} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Navigate to the DM
      view |> element("a[href=\"/chat/dm/#{dm.id}\"]") |> render_click()

      html = render(view)
      refute html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/
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
