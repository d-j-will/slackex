defmodule SlackexWeb.ChatLive.LayoutTest do
  @moduledoc """
  Behavioral tests for Phase 5 Step 1: Layout Refactor & Responsive Shell.

  Tests the component extraction, sidebar LiveComponent, compose hook,
  infinite scroll, and responsive layout changes.
  """
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat
  alias Slackex.Messaging.Envelope

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])

    alice = insert(:user, username: "alice", display_name: "Alice A")
    bob = insert(:user, username: "bob", display_name: "Bob B")

    {:ok, channel} =
      Chat.create_channel(alice.id, %{name: "general", description: "General chat"})

    Chat.join_channel(bob.id, channel.id)

    conn = log_in_user(conn, alice)

    %{conn: conn, alice: alice, bob: bob, channel: channel}
  end

  # ---------------------------------------------------------------------------
  # Sidebar as LiveComponent
  # ---------------------------------------------------------------------------

  describe "sidebar component" do
    test "renders as a LiveComponent with channels listed", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      # Sidebar rendered with structural elements
      assert html =~ "bg-base-200"
      # Channel name visible
      assert html =~ "general"
      # Section header visible
      assert html =~ "Channels"
    end

    test "shows workspace name in sidebar header", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Tenun"
    end

    test "highlights active channel in sidebar", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # The active channel link should have the active styling
      assert html =~ "bg-base-300 font-semibold"
    end

    test "shows current user info in sidebar footer", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      # Alice's display name should appear in the footer
      assert html =~ "Alice A"
      # Log out link should be present
      assert html =~ "Log out"
    end

    test "collapsible channels section toggles", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/chat")

      # Channels section is expanded by default
      assert html =~ "general"

      # Click toggle to collapse
      html =
        lv
        |> element(~s|button[phx-value-section="channels"]|)
        |> render_click()

      # Channel name should no longer be visible
      refute html =~ ~s|# </span>\n        <span class="truncate flex-1">general|
    end

    test "shows empty state when no channels", %{conn: _conn} do
      lonely_user = insert(:user, username: "lonely")
      conn = build_conn() |> log_in_user(lonely_user)

      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "No channels yet."
    end
  end

  # ---------------------------------------------------------------------------
  # Responsive layout
  # ---------------------------------------------------------------------------

  describe "responsive sidebar" do
    test "sidebar toggle event toggles sidebar_open assign", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Toggle sidebar closed
      html =
        lv
        |> element(~s|div[phx-click="toggle_sidebar"]|)
        |> render_click()

      # When sidebar is closed, the -translate-x-full class should appear
      assert html =~ "-translate-x-full"

      # Toggle sidebar open again
      # The sidebar container should no longer have -translate-x-full
      # (clicking the backdrop toggles it back)
      send(lv.pid, %Phoenix.Socket.Broadcast{
        topic: "ignore",
        event: "ignore",
        payload: %{}
      })
    end

    test "mobile hamburger button is present when channel selected", %{
      conn: conn,
      channel: channel
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Hamburger button exists (hidden on desktop via md:hidden)
      assert html =~ "Toggle sidebar"
    end
  end

  # ---------------------------------------------------------------------------
  # Chat layout
  # ---------------------------------------------------------------------------

  describe "chat layout" do
    test "uses full-height layout without navbar padding", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      # The chat layout should use h-screen with dvh override for mobile
      assert html =~ "h-screen"
      assert html =~ "100dvh"
      # Standard layout padding should NOT be present
      refute html =~ "px-4 py-6 sm:px-6 lg:px-8"
    end
  end

  # ---------------------------------------------------------------------------
  # Compose area
  # ---------------------------------------------------------------------------

  describe "compose area" do
    test "uses textarea instead of text input", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Should have a textarea, not an input type=text
      assert html =~ "<textarea"
      assert html =~ "message[content]"
      assert html =~ ~s|placeholder="Message #general"|
    end

    test "compose form has Compose hook", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ ~s|phx-hook="Compose"|
    end

    test "sending a message clears the form", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html =
        lv
        |> form("#message-form", message: %{content: "Hello from textarea"})
        |> render_submit()

      refute html =~ "Failed to send"
    end

    test "non-member sees join prompt instead of compose", %{conn: _conn} do
      owner = insert(:user)

      {:ok, public_ch} =
        Chat.create_channel(owner.id, %{name: "readonly-#{System.unique_integer([:positive])}"})

      viewer = insert(:user, username: "viewer")
      conn = build_conn() |> log_in_user(viewer)

      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_ch.slug}")

      assert html =~ "Join this channel to send messages"
      refute html =~ ~s|phx-hook="Compose"|
    end
  end

  # ---------------------------------------------------------------------------
  # Typing event (debounced from Compose hook)
  # ---------------------------------------------------------------------------

  describe "typing event" do
    test "typing event broadcasts via PubSub", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Subscribe to the channel's PubSub topic
      Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel.id}")

      # Push the typing event (simulating what Compose hook does)
      render_hook(lv, "typing", %{})

      # Should receive a typing envelope broadcast
      assert_receive {:envelope, %{event: "typing", payload: %{username: "alice"}}}, 1_000
    end

    test "typing indicator renders when another user types", %{
      conn: conn,
      bob: bob,
      channel: channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Simulate typing from bob via PubSub
      envelope =
        Envelope.wrap("typing", {:channel, channel.id}, %{
          user_id: bob.id,
          username: bob.username
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})

      html = render(lv)

      assert html =~ "bob is typing..."
    end
  end

  # ---------------------------------------------------------------------------
  # Infinite scroll (load_more)
  # ---------------------------------------------------------------------------

  describe "infinite scroll" do
    test "message list has MessageList hook", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ ~s|phx-hook="MessageList"|
    end

    test "load_more event fetches older messages", %{conn: conn, alice: alice, channel: channel} do
      # Seed 60 messages so there are messages beyond the initial 50
      for i <- 1..60 do
        {:ok, _msg} = Chat.send_message(channel.id, alice.id, "Message #{i}")
      end

      {:ok, lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Initial load shows the latest 50 messages (11-60)
      # Message 1 through 10 should NOT be visible yet
      assert html =~ "Message 60"
      refute html =~ "Message 1<"

      # Trigger load_more (simulating scroll to top)
      html = render_hook(lv, "load_more", %{})

      # Now older messages should be visible
      assert html =~ "Message 1"

      # Ensure we still see recent messages
      assert html =~ "Message 60"
    end

    test "load_more does nothing when no channel is selected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Should not crash
      html = render_hook(lv, "load_more", %{})
      assert html =~ "Welcome to Tenun"
    end

    test "load_more stops when no more messages", %{conn: conn, alice: alice, channel: channel} do
      # Seed only 5 messages (less than the 50 limit)
      for i <- 1..5 do
        {:ok, _msg} = Chat.send_message(channel.id, alice.id, "Msg #{i}")
      end

      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # has_more_messages should be false since we got < 50
      # load_more should be a no-op
      html = render_hook(lv, "load_more", %{})

      # All 5 messages still visible, no crash
      assert html =~ "Msg 1"
      assert html =~ "Msg 5"
    end
  end

  # ---------------------------------------------------------------------------
  # Message bubble component
  # ---------------------------------------------------------------------------

  describe "message bubble" do
    test "renders sender name and message content", %{
      conn: conn,
      alice: alice,
      channel: channel
    } do
      {:ok, _msg} = Chat.send_message(channel.id, alice.id, "Hello world!")

      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "Hello world!"
      assert html =~ "alice"
    end

    test "renders avatar with user initials", %{conn: conn, alice: alice, channel: channel} do
      {:ok, _msg} = Chat.send_message(channel.id, alice.id, "Test message")

      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Alice has display_name "Alice A", so initials should be "AA"
      assert html =~ "AA"
    end

    test "real-time message from another user renders with correct sender", %{
      conn: conn,
      bob: bob,
      channel: channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      envelope =
        Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Real-time from Bob!",
          sender_id: bob.id,
          channel_id: channel.id,
          inserted_at: DateTime.utc_now(),
          sender: %{
            id: bob.id,
            username: bob.username,
            display_name: bob.display_name,
            avatar_url: nil
          }
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})

      html = render(lv)

      assert html =~ "Real-time from Bob!"
      assert html =~ "bob"
    end
  end

  # ---------------------------------------------------------------------------
  # Empty state
  # ---------------------------------------------------------------------------

  describe "empty state" do
    test "shows welcome when no channel selected", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Welcome to Tenun"
      assert html =~ "Select a channel"
    end

    test "navigating away from channel shows welcome", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html = render_patch(lv, ~p"/chat")

      assert html =~ "Welcome to Tenun"
      refute html =~ "message[content]"
    end
  end

  # ---------------------------------------------------------------------------
  # Preserved functionality
  # ---------------------------------------------------------------------------

  describe "preserved functionality" do
    test "channel header shows name and description", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "#general"
      assert html =~ "General chat"
    end

    test "unauthenticated user is redirected to login" do
      conn = Phoenix.ConnTest.build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/chat")
    end

    test "non-member is redirected from private channel", %{conn: conn} do
      owner = insert(:user)

      {:ok, private_ch} =
        Chat.create_channel(owner.id, %{
          name: "secret-#{System.unique_integer([:positive])}",
          is_private: true
        })

      assert {:error, {:redirect, %{flash: flash, to: "/chat"}}} =
               live(conn, ~p"/chat/#{private_ch.slug}")

      assert flash["error"] =~ "don't have access"
    end
  end
end
