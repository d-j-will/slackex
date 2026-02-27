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

  # ---------------------------------------------------------------------------
  # Acceptance: Real-time unread increment via PubSub
  # ---------------------------------------------------------------------------

  describe "real-time unread increment" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_realtime")

      # Channel where user is owner, bob is member
      {:ok, channel} = Chat.create_channel(user.id, %{name: "realtime-test"})
      Chat.join_channel(bob.id, channel.id)
      Chat.mark_as_read(user.id, channel.id)

      # Second channel for non-active testing
      {:ok, channel2} = Chat.create_channel(user.id, %{name: "other-channel"})
      Chat.join_channel(bob.id, channel2.id)
      Chat.mark_as_read(user.id, channel2.id)

      # DM conversation
      {:ok, dm} = Chat.find_or_create_dm(user.id, bob.id)
      Chat.mark_dm_as_read(user.id, dm.id)

      %{bob: bob, channel: channel, channel2: channel2, dm: dm}
    end

    test "incoming message for non-active channel increments sidebar badge",
         %{conn: conn, bob: bob, channel: channel} do
      {:ok, view, html} = live(conn, ~p"/chat")

      # Baseline: no badge for channel
      refute html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/

      # Simulate a message arriving on channel PubSub topic
      envelope =
        Slackex.Messaging.Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Hello from bob",
          sender_id: bob.id,
          sender: bob,
          channel_id: channel.id,
          inserted_at: DateTime.utc_now()
        })

      Phoenix.PubSub.broadcast!(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})

      # Wait for the LiveView to process and re-render
      html = render(view)

      # Should now show badge with count 1
      assert html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/
    end

    test "incoming message for active channel does NOT increment badge",
         %{conn: conn, bob: bob, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Simulate a message arriving on active channel
      envelope =
        Slackex.Messaging.Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Hello while active",
          sender_id: bob.id,
          sender: bob,
          channel_id: channel.id,
          inserted_at: DateTime.utc_now()
        })

      Phoenix.PubSub.broadcast!(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})

      html = render(view)

      # No unread badge should appear for the active channel
      refute html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/
    end

    test "incoming DM for non-active conversation increments sidebar badge",
         %{conn: conn, bob: bob, dm: dm} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Simulate a DM message arriving
      envelope =
        Slackex.Messaging.Envelope.wrap("message.new", {:dm, dm.id}, %{
          id: System.unique_integer([:positive]),
          content: "DM from bob",
          sender_id: bob.id,
          sender: bob,
          dm_conversation_id: dm.id,
          inserted_at: DateTime.utc_now()
        })

      Phoenix.PubSub.broadcast!(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      html = render(view)

      assert html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/
    end

    test "entering a conversation with real-time unreads resets badge to 0",
         %{conn: conn, bob: bob, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Send a message to create an unread
      envelope =
        Slackex.Messaging.Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Unread msg",
          sender_id: bob.id,
          sender: bob,
          channel_id: channel.id,
          inserted_at: DateTime.utc_now()
        })

      Phoenix.PubSub.broadcast!(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})
      html = render(view)
      assert html =~ ~r/<span[^>]*badge-primary[^>]*>\s*1\s*<\/span>/

      # Now enter the channel -- badge should reset
      view |> element("a[href=\"/chat/#{channel.slug}\"]") |> render_click()
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
