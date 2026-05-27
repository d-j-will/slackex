defmodule SlackexWeb.ChatLive.ThreadTest do
  @moduledoc """
  LiveView-level acceptance tests for thread reply functionality in both
  channels and DMs. These tests verify routing, panel rendering, and reply
  creation — covering the bug fixed in v0.7.12 where DM threads crashed.
  """
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, user: user}
  end

  # ---------------------------------------------------------------------------
  # Channel threads — baseline behaviour
  # ---------------------------------------------------------------------------

  describe "channel thread: opening the panel" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_thread")
      {:ok, channel} = Chat.create_channel(user.id, %{name: "thread-channel"})
      Chat.join_channel(bob.id, channel.id)
      {:ok, message} = Chat.send_message(channel.id, bob.id, "hello threads")
      %{channel: channel, message: message}
    end

    test "open_thread event navigates to /chat/:slug/thread/:message_id", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "open_thread", %{"message-id" => "#{message.id}"})

      assert_patched(view, ~p"/chat/#{channel.slug}/thread/#{message.id}")
    end

    test "patching to thread URL renders the thread panel header", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      # Navigate to the channel first, then patch to the thread URL.
      # Navigating directly to the thread URL causes a duplicate-ID error because
      # the parent message appears in both the stream and the thread panel header —
      # a pre-existing production code issue. Patching avoids the stream re-render.
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      html = render_patch(view, ~p"/chat/#{channel.slug}/thread/#{message.id}")

      assert html =~ "Thread"
      assert html =~ "hello threads"
    end
  end

  describe "channel thread: closing the panel" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_close")
      {:ok, channel} = Chat.create_channel(user.id, %{name: "close-channel"})
      Chat.join_channel(bob.id, channel.id)
      {:ok, message} = Chat.send_message(channel.id, bob.id, "close this thread")
      %{channel: channel, message: message}
    end

    test "close_thread event patches back to /chat/:slug", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      render_patch(view, ~p"/chat/#{channel.slug}/thread/#{message.id}")

      render_click(view, "close_thread")

      assert_patched(view, ~p"/chat/#{channel.slug}")
    end
  end

  describe "channel thread: sending a reply" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_reply")
      {:ok, channel} = Chat.create_channel(user.id, %{name: "reply-channel"})
      Chat.join_channel(bob.id, channel.id)
      {:ok, message} = Chat.send_message(channel.id, bob.id, "parent message")
      %{channel: channel, message: message}
    end

    test "submitting the reply form sends the reply and shows it in the thread panel", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
      render_patch(view, ~p"/chat/#{channel.slug}/thread/#{message.id}")

      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"reply" => %{"content" => "a thread reply"}})

      # render/1 flushes the parent LiveView's handle_info queue, which is where
      # Messaging.send_reply is called (via the {:send_thread_reply, ...} message
      # sent from the component to its parent process).
      render(view)

      replies = Chat.list_thread(message.id)
      assert length(replies) == 1
      assert hd(replies).content == "a thread reply"
    end
  end

  # ---------------------------------------------------------------------------
  # DM threads — the bug fixed in v0.7.12
  # ---------------------------------------------------------------------------

  describe "DM thread: opening the panel" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_dm_thread")
      {:ok, dm} = Chat.find_or_create_dm(user.id, bob.id)
      {:ok, message} = Chat.send_dm(dm.id, bob.id, "DM parent message")
      %{dm: dm, message: message}
    end

    test "open_thread event in a DM navigates to /chat/dm/:dm_id/thread/:message_id", %{
      conn: conn,
      dm: dm,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      render_click(view, "open_thread", %{"message-id" => "#{message.id}"})

      assert_patched(view, ~p"/chat/dm/#{dm.id}/thread/#{message.id}")
    end

    test "patching to DM thread URL renders the thread panel header", %{
      conn: conn,
      dm: dm,
      message: message
    } do
      # Navigate to the DM first, then patch to the thread URL to avoid the
      # duplicate-ID error that occurs when navigating directly to the thread URL
      # (parent message appears in both stream and thread panel header).
      {:ok, view, _html} = live(conn, ~p"/chat/dm/#{dm.id}")
      html = render_patch(view, ~p"/chat/dm/#{dm.id}/thread/#{message.id}")

      assert html =~ "Thread"
      assert html =~ "DM parent message"
    end
  end

  describe "DM thread: closing the panel" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_dm_close")
      {:ok, dm} = Chat.find_or_create_dm(user.id, bob.id)
      {:ok, message} = Chat.send_dm(dm.id, bob.id, "DM close test")
      %{dm: dm, message: message}
    end

    test "close_thread event in a DM patches back to /chat/dm/:dm_id", %{
      conn: conn,
      dm: dm,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/dm/#{dm.id}")
      render_patch(view, ~p"/chat/dm/#{dm.id}/thread/#{message.id}")

      render_click(view, "close_thread")

      assert_patched(view, ~p"/chat/dm/#{dm.id}")
    end
  end

  describe "DM thread: sending a reply" do
    setup %{user: user} do
      bob = insert(:user, username: "bob_dm_reply")
      {:ok, dm} = Chat.find_or_create_dm(user.id, bob.id)
      {:ok, message} = Chat.send_dm(dm.id, bob.id, "DM reply parent")
      %{dm: dm, message: message}
    end

    test "submitting the reply form in a DM thread creates the reply correctly", %{
      conn: conn,
      dm: dm,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chat/dm/#{dm.id}")
      render_patch(view, ~p"/chat/dm/#{dm.id}/thread/#{message.id}")

      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"reply" => %{"content" => "DM thread reply"}})

      # render/1 flushes the parent LiveView's handle_info queue so
      # Messaging.send_reply is called before we query the DB.
      render(view)

      replies = Chat.list_thread(message.id)
      assert length(replies) == 1
      assert hd(replies).content == "DM thread reply"
    end

    test "a reply rendered in both the main stream and the thread panel keeps unique DOM ids",
         %{conn: conn, dm: dm, message: message, user: user} do
      {:ok, view, _html} = live(conn, ~p"/chat/dm/#{dm.id}")
      render_patch(view, ~p"/chat/dm/#{dm.id}/thread/#{message.id}")

      # Drive the real reply path: Messaging.send_reply broadcasts message.new on
      # the DM topic (-> main :messages stream) AND thread.reply on the thread
      # topic (-> thread panel). The reply then renders in BOTH containers; if
      # they share a DOM id, render/1 raises "Duplicate id" (the CI flake).
      {:ok, _reply} =
        Slackex.Messaging.send_reply(dm.id, :dm, user.id, message.id, "DM dup-id reply")

      # First render flushes message.new + thread.reply; the second flushes the
      # thread-panel send_update so the reply is rendered in both containers.
      _ = render(view)
      html = render(view)

      assert html =~ "DM dup-id reply"
    end
  end
end
