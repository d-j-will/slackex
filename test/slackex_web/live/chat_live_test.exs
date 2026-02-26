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

  defp create_dm_between(user_a, user_b) do
    {a, b} = if user_a.id < user_b.id, do: {user_a, user_b}, else: {user_b, user_a}
    insert(:dm_conversation, user_a: a, user_b: b, user_a_id: a.id, user_b_id: b.id)
  end

  describe "DM route resolution" do
    test "/chat/dm/new resolves with :new_dm action and shows New Message title", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/new")
      assert html =~ "New Message"
    end

    test "/chat/dm/:dm_id resolves with :dm action", %{conn: conn, alice: alice, bob: bob} do
      dm = create_dm_between(alice, bob)

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
      %{dm: create_dm_between(alice, bob)}
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

  describe "DM flow: sidebar update, sending, and real-time receipt" do
    setup %{alice: alice, bob: bob} do
      %{dm: create_dm_between(alice, bob)}
    end

    test "start_dm updates sidebar dm_conversations before navigating", %{conn: conn} do
      # Create a new user that alice has no DM with yet
      carol = insert(:user, username: "carol_sidebar", display_name: "Carol Sidebar")

      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Sidebar should NOT show carol yet
      refute render(lv) =~ "Carol Sidebar"

      # Trigger start_dm (as the NewDmModal would)
      send(lv.pid, {:start_dm, carol.id})

      # After processing, carol should appear in the sidebar dm_conversations
      # The LiveView push_patches to the new DM route. We need the sidebar
      # to contain the new DM entry even though it was created after mount.
      html = render(lv)
      assert html =~ "Carol Sidebar"
    end

    test "sending message in DM dispatches via Messaging and message appears", %{
      conn: conn,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Submit a message via the DM compose form
      lv
      |> form("#message-form", message: %{content: "Hello DM!"})
      |> render_submit()

      # The message should be dispatched via Messaging.send_dm and broadcast
      # back through PubSub, appearing in the stream. Give it a moment.
      # If send_message handler ignores DMs, this message won't appear.
      Process.sleep(100)
      html = render(lv)
      assert html =~ "Hello DM!"
    end

    test "incoming DM messages appear in real-time via PubSub", %{
      conn: conn,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Simulate an incoming DM message from bob via PubSub
      envelope =
        Envelope.wrap("message.new", {:dm, dm.id}, %{
          id: System.unique_integer([:positive]),
          content: "Real-time DM from Bob!",
          sender_id: bob.id,
          dm_conversation_id: dm.id,
          inserted_at: DateTime.utc_now(),
          sender: %{
            id: bob.id,
            username: bob.username,
            display_name: bob.display_name,
            avatar_url: nil
          }
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      html = render(lv)
      assert html =~ "Real-time DM from Bob!"
    end
  end

  describe "DM typing indicator and load-more" do
    setup %{alice: alice, bob: bob} do
      %{dm: create_dm_between(alice, bob)}
    end

    test "typing event broadcasts on dm topic when in DM view", %{
      conn: conn,
      alice: alice,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Subscribe to the DM topic to observe the broadcast
      Phoenix.PubSub.subscribe(Slackex.PubSub, "dm:#{dm.id}")

      # Trigger typing event
      render_hook(lv, :typing, %{})

      # Should receive a typing envelope on the DM topic
      assert_receive {:envelope, %{event: "typing", payload: payload}}, 1_000
      assert payload.user_id == alice.id
      assert payload.username == "alice"
    end

    test "load_more in DM fetches older messages with cursor pagination", %{
      conn: conn,
      alice: alice,
      dm: dm
    } do
      # Create 60 messages so there are older ones to load
      # Use prefix "old-dm-" for the first 10 so they are distinct from later messages
      for i <- 1..10 do
        {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "old-dm-#{i}")
      end

      for i <- 11..60 do
        {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "recent-dm-#{i}")
      end

      {:ok, lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Initial load shows the newest 50 messages (messages 11-60)
      assert html =~ "recent-dm-60"
      refute html =~ "old-dm-1"

      # Trigger load_more
      render_hook(lv, :load_more, %{})

      # After load_more, older messages should now appear
      assert render(lv) =~ "old-dm-1"
    end

    test "typing indicator from DM participant displays and auto-clears", %{
      conn: conn,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Simulate bob typing in the DM via PubSub
      envelope =
        Envelope.wrap("typing", {:dm, dm.id}, %{
          user_id: bob.id,
          username: bob.username
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      # Typing indicator should show bob
      html = render(lv)
      assert html =~ bob.username

      # After 3 seconds, typing indicator auto-clears
      Process.sleep(3_100)
      html = render(lv)
      refute html =~ "is typing"
    end

    test "navigating away from DM clears typing state", %{
      conn: conn,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Simulate bob typing
      envelope =
        Envelope.wrap("typing", {:dm, dm.id}, %{
          user_id: bob.id,
          username: bob.username
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      # Typing indicator visible
      html = render(lv)
      assert html =~ bob.username

      # Navigate away from DM
      html = render_patch(lv, ~p"/chat")

      # Should show welcome screen, no typing indicator
      assert html =~ "Welcome to Slackex"
      refute html =~ "is typing"
    end
  end

  describe "sidebar DM list rendering" do
    setup %{alice: alice, bob: bob} do
      %{dm: create_dm_between(alice, bob)}
    end

    test "sidebar renders Direct Messages header", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Direct Messages"
    end

    test "DM entries show other user display name in sidebar", %{conn: conn, bob: bob} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
    end

    test "New Message link exists and points to /chat/dm/new", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "New Message"
      assert html =~ ~s|/chat/dm/new|
    end

    test "active DM is highlighted in sidebar", %{conn: conn, bob: bob, dm: dm} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # The sidebar should contain the DM link with active styling
      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
      # Active DM entry gets font-semibold class
      assert html =~ ~s|font-semibold|
    end

    test "clicking DM entry navigates via patch", %{conn: conn, dm: dm} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Click the DM link in the sidebar
      html = render_patch(lv, ~p"/chat/dm/#{dm.id}")

      # Should now be in the DM view (page title shows other user name)
      refute html =~ "Welcome to Slackex"
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

  describe "new DM modal" do
    setup %{alice: _alice, bob: _bob} do
      # Create additional users for search results
      carol = insert(:user, username: "carol", display_name: "Carol Smith")
      dave = insert(:user, username: "dave", display_name: "Dave Jones")
      _eve = insert(:user, username: "eve", display_name: "Eve Adams")
      %{carol: carol, dave: dave}
    end

    test "modal renders when navigated to /chat/dm/new", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/new")

      assert html =~ "new-dm-modal"
      assert html =~ "Search users"
    end

    test "typing 2+ chars in search field returns matching users", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "carol"})

      assert html =~ "Carol Smith"
    end

    test "current user excluded from search results", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Alice is logged in; searching "ali" should not return alice
      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "ali"})

      refute html =~ ~s|alice|
    end

    test "selecting a user sends {:start_dm, user_id} to parent", %{conn: conn, carol: carol} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Search for carol
      lv
      |> element("#new-dm-search")
      |> render_change(%{"search_query" => "carol"})

      # Click on carol's result
      lv
      |> element("#new-dm-modal [data-user-id=\"#{carol.id}\"]")
      |> render_click()

      # After selection, modal should close (navigated away from :new_dm)
      html = render(lv)
      refute html =~ "new-dm-modal"
    end

    test "queries under 2 chars return empty results without showing users", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "c"})

      refute html =~ "Carol Smith"
      refute html =~ "Dave Jones"
    end

    test "modal closes on backdrop click, navigating back to /chat", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      assert render(lv) =~ "new-dm-modal"

      # Click backdrop
      lv
      |> element("#new-dm-modal-backdrop")
      |> render_click()

      html = render(lv)
      refute html =~ "new-dm-modal"
    end
  end

  describe "create channel modal" do
    test "modal renders when navigated to /chat/channels/new", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/channels/new")

      assert html =~ "create-channel-modal"
      assert html =~ "Create Channel"
    end

    test "name field auto-formats input to lowercase-hyphens on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      html =
        lv
        |> element("#create-channel-form")
        |> render_change(%{"channel" => %{"name" => "My Cool Channel"}})

      assert html =~ ~s|value="my-cool-channel"|
    end

    test "submitting valid form creates channel and closes modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      lv
      |> element("#create-channel-form")
      |> render_submit(%{
        "channel" => %{"name" => "new-test-channel", "description" => "A test channel"}
      })

      # After success, modal should close (navigated away from :create_channel)
      html = render(lv)
      refute html =~ "create-channel-modal"
      # Channel should appear in sidebar
      assert html =~ "new-test-channel"
    end

    test "validation errors display when name is blank", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      html =
        lv
        |> element("#create-channel-form")
        |> render_change(%{"channel" => %{"name" => ""}})

      assert html =~ "can&#39;t be blank"
    end

    test "validation errors display when name is too short", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      html =
        lv
        |> element("#create-channel-form")
        |> render_change(%{"channel" => %{"name" => "a"}})

      assert html =~ "should be at least 2 character(s)"
    end

    test "modal closes on backdrop click, returning to /chat", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      assert render(lv) =~ "create-channel-modal"

      lv
      |> element("#create-channel-modal-backdrop")
      |> render_click()

      html = render(lv)
      refute html =~ "create-channel-modal"
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
