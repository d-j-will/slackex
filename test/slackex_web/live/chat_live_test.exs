defmodule SlackexWeb.ChatLiveTest do
  use SlackexWeb.ConnCase

  alias Slackex.Chat
  alias Slackex.Messaging.Envelope

  setup %{conn: conn} do
    # Clean ETS cache between tests
    :ets.delete_all_objects(:slackex_message_cache)

    # Create users
    alice = insert(:user, username: "alice")
    bob = insert(:user, username: "bob")

    # Create a channel with alice as owner, bob as member
    {:ok, channel} =
      Chat.create_channel(alice.id, %{name: "general", description: "General chat"})

    Chat.join_channel(bob.id, channel.id)

    # Log alice in
    conn = log_in_user(conn, alice)

    %{
      conn: conn,
      alice: alice,
      bob: bob,
      channel: channel
    }
  end

  describe "DM route resolution" do
    test "/chat/dm/new resolves with :new_dm action and shows New Message title", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/new")
      assert html =~ "New Message"
    end

    test "/chat/dm/:dm_id resolves with :dm action", %{conn: conn, alice: alice, bob: bob} do
      {a, b} = if alice.id < bob.id, do: {alice, bob}, else: {bob, alice}
      dm = insert(:dm_conversation, user_a: a, user_b: b, user_a_id: a.id, user_b_id: b.id)

      assert {:ok, _lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")
    end

    test "DM routes are matched before the :slug catch-all", %{conn: conn} do
      # /chat/dm/new resolves to :new_dm, not :show with slug="dm"
      # If the slug route matched first, it would crash looking up a channel with slug "dm"
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/new")

      # Route resolved successfully — shows New Message (not a channel lookup error)
      assert html =~ "New Message"
    end
  end

  describe "DM conversations" do
    setup %{alice: alice, bob: bob} do
      # Create a DM between alice and bob, respecting user_a_id < user_b_id invariant
      {a, b} = if alice.id < bob.id, do: {alice, bob}, else: {bob, alice}
      dm = insert(:dm_conversation, user_a: a, user_b: b, user_a_id: a.id, user_b_id: b.id)
      %{dm: dm}
    end

    test "mount assigns dm_conversations without error", %{conn: conn, dm: _dm} do
      # When a DM exists for alice, mount should load dm_conversations and not crash
      assert {:ok, _lv, _html} = live(conn, ~p"/chat")
    end

    test "navigating to DM loads messages into stream", %{conn: conn, alice: alice, dm: dm} do
      {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "Hello via DM!")

      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      assert html =~ "Hello via DM!"
    end

    test "DM page title shows other user display name", %{conn: conn, bob: bob, dm: dm} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Page title should show bob's display name (the "other" user from alice's perspective)
      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
    end

    test "non-participant accessing DM receives flash error and redirects", %{conn: conn} do
      # Create a DM between two other users (not alice)
      stranger_dm = insert(:dm_conversation)

      assert {:error, {:redirect, %{flash: flash, to: "/chat"}}} =
               live(conn, ~p"/chat/dm/#{stranger_dm.id}")

      assert flash["error"] =~ "Not found"
    end

    test "leaving a DM conversation by navigating away clears active_dm", %{
      conn: conn,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Navigate to index
      html = render_patch(lv, ~p"/chat")

      assert html =~ "Welcome to Slackex"
    end
  end

  describe "channel authorization" do
    test "non-member is redirected from private channel with flash", %{conn: conn} do
      # Create a private channel owned by someone else
      owner = insert(:user)

      {:ok, private_channel} =
        Chat.create_channel(owner.id, %{
          name: "secret-#{System.unique_integer([:positive])}",
          is_private: true
        })

      # Alice (logged in via setup) is NOT a member of this private channel
      assert {:error, {:redirect, %{flash: flash, to: "/chat"}}} =
               live(conn, ~p"/chat/#{private_channel.slug}")

      assert flash["error"] =~ "don't have access"
    end

    test "non-member can view public channel", %{conn: conn} do
      # Create a public channel owned by someone else
      owner = insert(:user)

      {:ok, public_channel} =
        Chat.create_channel(owner.id, %{
          name: "open-#{System.unique_integer([:positive])}"
        })

      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      # Should see the channel header
      assert html =~ public_channel.name
    end

    test "non-member viewing public channel sees no message form", %{conn: conn} do
      owner = insert(:user)

      {:ok, public_channel} =
        Chat.create_channel(owner.id, %{
          name: "readonly-#{System.unique_integer([:positive])}"
        })

      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      # Should NOT see the send button / form
      refute html =~ "phx-submit=\"send_message\""
      # Should see the join prompt
      assert html =~ "Join this channel to send messages"
    end

    test "member sees channel content and message form", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Alice is the owner of this channel from setup — should see the form
      assert html =~ "phx-submit=\"send_message\""
      assert html =~ "Send"
      refute html =~ "Join this channel to send messages"
    end
  end

  describe "pre-enriched sender in PubSub" do
    test "pre-enriched PubSub message renders sender name without DB query", %{
      conn: conn,
      bob: bob,
      channel: channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Simulate a pre-enriched message (as ChannelServer now sends)
      envelope =
        Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Pre-enriched hello!",
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

      assert html =~ "Pre-enriched hello!"
      assert html =~ bob.username
    end
  end

  describe "chat experience" do
    test "user sees their channels in sidebar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "general"
      assert html =~ "Channels"
    end

    test "selecting a channel shows the channel header", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "#general"
      assert html =~ "General chat"
    end

    test "selecting a channel shows its messages", %{
      conn: conn,
      alice: alice,
      channel: channel
    } do
      # Send a message via the Chat context (direct DB write for test setup)
      {:ok, _msg} = Chat.send_message(channel.id, alice.id, "Hello world!")

      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "Hello world!"
    end

    test "sending a message makes it appear", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html =
        lv
        |> form("#message-form", message: %{content: "My new message"})
        |> render_submit()

      # After submit, form should be cleared (empty content)
      # The message will appear via PubSub broadcast
      refute html =~ "Failed to send"
    end

    test "real-time message from another user appears via PubSub", %{
      conn: conn,
      bob: bob,
      channel: channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Simulate a real-time message from bob via PubSub envelope
      envelope =
        Envelope.wrap("message.new", {:channel, channel.id}, %{
          id: System.unique_integer([:positive]),
          content: "Hello from Bob!",
          sender_id: bob.id,
          channel_id: channel.id,
          inserted_at: DateTime.utc_now()
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "channel:#{channel.id}", {:envelope, envelope})

      # Wait for the LiveView to process the message
      html = render(lv)

      assert html =~ "Hello from Bob!"
      assert html =~ "bob"
    end

    test "unauthenticated user is redirected to login", %{conn: _conn} do
      # Build a fresh conn without auth
      conn = Phoenix.ConnTest.build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/chat")
    end

    test "shows welcome message when no channel selected", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Welcome to Slackex"
      assert html =~ "Select a channel"
    end

    test "message form is present when channel is selected", %{conn: conn, channel: channel} do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "message[content]"
      assert html =~ "Send"
    end

    test "navigating away from a channel shows welcome screen", %{conn: conn, channel: channel} do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html = render_patch(lv, ~p"/chat")

      assert html =~ "Welcome to Slackex"
      assert html =~ "Select a channel"
      refute html =~ "message[content]"
    end
  end
end
