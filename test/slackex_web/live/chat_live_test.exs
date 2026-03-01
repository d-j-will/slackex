defmodule SlackexWeb.ChatLiveTest do
  use SlackexWeb.ConnCase

  import Ecto.Query

  alias Slackex.Chat
  alias Slackex.Messaging.Envelope
  alias Slackex.Notifications.OnlineTracker

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
      # back through PubSub, appearing in the stream.
      # render(lv) processes pending messages in the LiveView mailbox.
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

      # Simulate the auto-clear timer firing by sending the clear message directly
      send(lv.pid, {:clear_typing, bob.username})
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

    test "current user included in search results for self-DM", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Alice is logged in; searching "ali" should return alice (self-DM for notes)
      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "ali"})

      assert html =~ ~s|alice|
    end

    test "selecting a user sends {:start_dm_request, user_id} to parent", %{
      conn: conn,
      alice: alice,
      carol: carol
    } do
      # Make alice's account old enough to pass create_dm_request checks
      Slackex.Repo.update_all(
        from(u in Slackex.Accounts.User, where: u.id == ^alice.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)]
      )

      # Alice and carol must share a channel for the request to succeed
      channel = Chat.get_channel_by_slug!("general")
      Chat.join_channel(carol.id, channel.id)

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Search for carol
      lv
      |> element("#new-dm-search")
      |> render_change(%{"search_query" => "carol"})

      # Click on carol's result
      lv
      |> element("#new-dm-modal [data-user-id=\"#{carol.id}\"]")
      |> render_click()

      # After selection, modal should close (navigated to /chat with flash)
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

  describe "new DM modal: blocked user filtering" do
    setup %{alice: alice, bob: _bob} do
      # Create users with searchable names
      carol = insert(:user, username: "carol_block", display_name: "Carol Blocktest")
      dave = insert(:user, username: "dave_block", display_name: "Dave Blocktest")
      %{alice: alice, carol: carol, dave: dave}
    end

    test "blocked users do not appear in search results", %{
      conn: conn,
      alice: alice,
      carol: carol
    } do
      # Alice blocks carol
      {:ok, _} = Chat.block_user(alice.id, carol.id)

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "carol_block"})

      # Carol should NOT appear because alice blocked her
      refute html =~ "Carol Blocktest"
    end

    test "users who blocked the current user are also excluded from search", %{
      conn: conn,
      alice: alice,
      dave: dave
    } do
      # Dave blocks alice (reverse direction)
      {:ok, _} = Chat.block_user(dave.id, alice.id)

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "dave_block"})

      # Dave should NOT appear because dave blocked alice
      refute html =~ "Dave Blocktest"
    end

    test "non-blocked users still appear in search results", %{
      conn: conn,
      alice: alice,
      carol: carol,
      dave: _dave
    } do
      # Alice blocks carol only -- dave is NOT blocked
      {:ok, _} = Chat.block_user(alice.id, carol.id)

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      html =
        lv
        |> element("#new-dm-search")
        |> render_change(%{"search_query" => "block"})

      # Dave should still appear; carol should not
      assert html =~ "Dave Blocktest"
      refute html =~ "Carol Blocktest"
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

    test "validation errors display when name is blank and channel is not created", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      html =
        lv
        |> element("#create-channel-form")
        |> render_change(%{"channel" => %{"name" => ""}})

      assert html =~ "can&#39;t be blank"

      # Verify no channel was created in the DB with an empty name
      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_channel_by_slug!("")
      end
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

  describe "create channel: sidebar button and post-creation flow" do
    test "sidebar shows + button in channels section linking to /chat/channels/new", %{
      conn: conn
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ ~s|/chat/channels/new|
      # The button should be in the channels section header area
      assert html =~ "+" || html =~ "plus"
    end

    test "after channel creation, sidebar includes the new channel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      lv
      |> element("#create-channel-form")
      |> render_submit(%{
        "channel" => %{"name" => "sidebar-check", "description" => "Checking sidebar"}
      })

      html = render(lv)
      assert html =~ "sidebar-check"
    end

    test "after channel creation, user navigates to the new channel view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      lv
      |> element("#create-channel-form")
      |> render_submit(%{
        "channel" => %{"name" => "nav-test-chan", "description" => "Navigation test"}
      })

      html = render(lv)
      # Should be viewing the channel (header shows channel name)
      assert html =~ "#nav-test-chan"
      # Modal should be closed
      refute html =~ "create-channel-modal"
    end

    test "created channel shows current user as owner", %{conn: conn, alice: alice} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      lv
      |> element("#create-channel-form")
      |> render_submit(%{
        "channel" => %{"name" => "owner-check", "description" => "Owner test"}
      })

      # Verify alice is the owner via Chat.get_role
      channel = Chat.get_channel_by_slug!("owner-check")
      assert Chat.get_role(alice.id, channel.id) == "owner"
    end
  end

  describe "browse channels modal" do
    setup %{alice: alice, conn: conn} do
      # Create public channels that alice has NOT joined
      owner = insert(:user, username: "chan_owner")

      {:ok, dev_channel} =
        Chat.create_channel(owner.id, %{
          name: "dev-talk",
          description: "Developer discussions"
        })

      {:ok, design_channel} =
        Chat.create_channel(owner.id, %{
          name: "design-hub",
          description: "Design team space"
        })

      # Create a channel alice IS a member of (from setup: "general")
      # so we can verify it's excluded

      %{
        conn: conn,
        alice: alice,
        dev_channel: dev_channel,
        design_channel: design_channel
      }
    end

    # -- Acceptance tests (Phase 1) --

    test "modal renders when navigated to /chat/channels/browse", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")

      assert html =~ "browse-channels-modal"
      assert html =~ "Browse Channels"
    end

    test "lists all public channels with join status", %{
      conn: conn,
      dev_channel: dev_channel,
      design_channel: design_channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      # Render just the modal component to avoid matching sidebar content
      modal_html = lv |> element("#browse-channels-modal") |> render()

      # Should show unjoined public channels with Join button
      assert modal_html =~ dev_channel.name
      assert modal_html =~ design_channel.name

      # Should also show "general" (alice is a member) with Joined badge
      assert modal_html =~ "general"
      assert modal_html =~ "Joined"
    end

    test "clicking Join adds user to channel and sends {:channel_joined, channel}", %{
      conn: conn,
      alice: alice,
      dev_channel: dev_channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      # Click Join on dev-talk
      lv
      |> element(
        ~s(#browse-channels-modal [phx-click="join"][phx-value-channel-id="#{dev_channel.id}"])
      )
      |> render_click()

      # Verify subscription was actually created in the database
      assert Chat.get_role(alice.id, dev_channel.id) != nil

      # After join, the channel should no longer appear in the browse list
      # (because user is now a member) and the parent should have received
      # {:channel_joined, channel}
      html = render(lv)
      refute html =~ "browse-channels-modal"
    end

    # -- Unit-level tests (Phase 2) --

    test "each channel entry displays name, description, and member count", %{
      conn: conn,
      dev_channel: _dev_channel
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")

      assert html =~ "dev-talk"
      assert html =~ "Developer discussions"
      # Member count badge (owner is 1 member)
      assert html =~ "1 member"
    end

    test "search input filters displayed channels by name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      html =
        lv
        |> element("#browse-channels-search")
        |> render_change(%{"search_query" => "dev"})

      assert html =~ "dev-talk"
      refute html =~ "design-hub"
    end

    test "search filter is case-insensitive", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      html =
        lv
        |> element("#browse-channels-search")
        |> render_change(%{"search_query" => "DEV"})

      assert html =~ "dev-talk"
      refute html =~ "design-hub"
    end

    test "empty state shown when no channels match search", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      html =
        lv
        |> element("#browse-channels-search")
        |> render_change(%{"search_query" => "zzz-no-match"})

      assert html =~ "No channels found"
    end

    test "modal closes on backdrop click, navigating back to /chat", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      assert render(lv) =~ "browse-channels-modal"

      lv
      |> element("#browse-channels-modal-backdrop")
      |> render_click()

      html = render(lv)
      refute html =~ "browse-channels-modal"
    end

    test "joined channel shows Joined badge in browse modal on re-open", %{
      conn: conn,
      dev_channel: dev_channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      # dev-talk should be in the browse list initially with a Join button
      modal_html = lv |> element("#browse-channels-modal") |> render()
      assert modal_html =~ dev_channel.name
      assert modal_html =~ "btn btn-primary btn-sm"

      # Join dev-talk
      lv
      |> element(
        ~s(#browse-channels-modal [phx-click="join"][phx-value-channel-id="#{dev_channel.id}"])
      )
      |> render_click()

      # Navigate back to browse modal
      render_patch(lv, ~p"/chat/channels/browse")

      # dev-talk should still appear but now with Joined badge instead of Join button
      modal_html = lv |> element("#browse-channels-modal") |> render()
      assert modal_html =~ "dev-talk"
      assert modal_html =~ "Joined"
    end
  end

  describe "DM conversation broadcast: recipient sidebar real-time update" do
    test "creating a new DM broadcasts to recipient, updating their sidebar in real-time", %{
      conn: _conn
    } do
      # Create a user with a unique display name that won't appear anywhere else
      carol = insert(:user, username: "carol_rt", display_name: "Carol Realtime")
      dave = insert(:user, username: "dave_rt", display_name: "Dave Broadcast")

      # Open a LiveView session as carol (the recipient)
      carol_conn = build_conn() |> log_in_user(carol)
      {:ok, carol_lv, carol_html} = live(carol_conn, ~p"/chat")

      # Carol's sidebar should NOT show Dave yet
      refute carol_html =~ "Dave Broadcast"

      # Dave initiates a DM with carol (triggers find_or_create_dm which should broadcast)
      dave_conn = build_conn() |> log_in_user(dave)
      {:ok, dave_lv, _html} = live(dave_conn, ~p"/chat")
      send(dave_lv.pid, {:start_dm, carol.id})

      # Process pending messages in dave's LiveView to ensure DM creation completes
      render(dave_lv)

      # Carol's sidebar should now show Dave (the new DM partner) without page refresh
      # render(carol_lv) processes pending PubSub messages in carol's LiveView mailbox
      carol_html = render(carol_lv)
      assert carol_html =~ "Dave Broadcast"
    end

    test "reopening an existing DM does NOT broadcast to recipient", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      # Create the DM first so it already exists
      {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Subscribe to bob's user topic to observe broadcasts
      Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{bob.id}")

      # Alice reopens the existing DM
      {:ok, alice_lv, _html} = live(conn, ~p"/chat")
      send(alice_lv.pid, {:start_dm, bob.id})

      # Process pending messages in alice's LiveView to ensure the reopen completes
      render(alice_lv)

      # No :dm_conversation_new broadcast should have been sent
      refute_received {:dm_conversation_new, _}
    end
  end

  describe "browse channels: sidebar link and join flow" do
    setup %{alice: alice, conn: conn} do
      owner = insert(:user, username: "browse_owner")

      {:ok, browsable_channel} =
        Chat.create_channel(owner.id, %{
          name: "browsable-chan",
          description: "A browsable channel"
        })

      %{conn: conn, alice: alice, browsable_channel: browsable_channel}
    end

    test "Browse link appears in sidebar channels section", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ ~s|/chat/channels/browse|
    end

    test "after joining a channel, sidebar updates to include the joined channel", %{
      conn: conn,
      browsable_channel: browsable_channel
    } do
      {:ok, lv, html} = live(conn, ~p"/chat")

      # Sidebar should NOT show browsable-chan yet (alice is not a member)
      refute html =~ "browsable-chan"

      # Navigate to browse modal and join
      render_patch(lv, ~p"/chat/channels/browse")

      lv
      |> element(
        ~s(#browse-channels-modal [phx-click="join"][phx-value-channel-id="#{browsable_channel.id}"])
      )
      |> render_click()

      # After joining, sidebar should include the joined channel
      html = render(lv)
      assert html =~ "browsable-chan"
    end

    test "after joining, user navigates to the joined channel view", %{
      conn: conn,
      browsable_channel: browsable_channel
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      lv
      |> element(
        ~s(#browse-channels-modal [phx-click="join"][phx-value-channel-id="#{browsable_channel.id}"])
      )
      |> render_click()

      # After join, should navigate to the channel view
      html = render(lv)
      assert html =~ "#browsable-chan"
      refute html =~ "browse-channels-modal"
    end
  end

  describe "channel header join and leave buttons" do
    setup %{conn: conn, alice: alice} do
      # Create a public channel owned by someone else
      owner = insert(:user, username: "chan_header_owner")

      {:ok, public_channel} =
        Chat.create_channel(owner.id, %{
          name: "joinable-#{System.unique_integer([:positive])}",
          description: "A public channel"
        })

      # Alice is NOT a member of this channel
      # Bob will be added as a member (non-owner) for leave tests
      bob_member = insert(:user, username: "bob_member")
      Chat.join_channel(bob_member.id, public_channel.id)

      %{
        conn: conn,
        alice: alice,
        owner: owner,
        bob_member: bob_member,
        public_channel: public_channel
      }
    end

    # AC1: Non-member viewing public channel sees "Join Channel" button
    test "non-member viewing public channel sees Join Channel button", %{
      conn: conn,
      public_channel: public_channel
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      assert html =~ "Join Channel"
    end

    # AC2: Clicking Join Channel adds membership, enables compose, updates sidebar
    test "clicking Join Channel adds membership and enables compose area", %{
      conn: conn,
      public_channel: public_channel
    } do
      {:ok, lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      # Should see join button, not compose area
      assert html =~ "Join Channel"
      refute html =~ "phx-submit=\"send_message\""

      # Click Join Channel
      lv
      |> element("button", "Join Channel")
      |> render_click()

      html = render(lv)

      # After joining: compose area visible, join button gone
      refute html =~ "Join Channel"
      assert html =~ "phx-submit=\"send_message\""
      # Channel should appear in sidebar
      assert html =~ public_channel.name
    end

    # AC3: Member (non-owner) sees "Leave Channel" button
    test "member who is not owner sees Leave Channel button", %{
      bob_member: bob_member,
      public_channel: public_channel
    } do
      conn = build_conn() |> log_in_user(bob_member)
      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      assert html =~ "Leave Channel"
    end

    # AC4: Clicking Leave Channel removes membership, navigates to /chat, updates sidebar
    test "clicking Leave Channel removes membership and navigates to /chat", %{
      bob_member: bob_member,
      public_channel: public_channel
    } do
      conn = build_conn() |> log_in_user(bob_member)
      {:ok, lv, _html} = live(conn, ~p"/chat/#{public_channel.slug}")

      lv
      |> element("button", "Leave Channel")
      |> render_click()

      # Should navigate to /chat (welcome screen)
      html = render(lv)
      assert html =~ "Welcome to Slackex"
      # Channel should no longer be in the sidebar channels list
      sidebar_html = lv |> element("aside") |> render()
      refute sidebar_html =~ public_channel.name
    end

    # AC5: Channel owner does not see Leave Channel button
    test "channel owner does not see Leave Channel button", %{
      owner: owner,
      public_channel: public_channel
    } do
      conn = build_conn() |> log_in_user(owner)
      {:ok, _lv, html} = live(conn, ~p"/chat/#{public_channel.slug}")

      refute html =~ "Leave Channel"
      refute html =~ "Join Channel"
    end
  end

  describe "DM block button in conversation header" do
    setup %{alice: alice, bob: bob} do
      %{dm: create_dm_between(alice, bob)}
    end

    test "block button visible in active DM conversation header", %{conn: conn, dm: dm} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      assert html =~ "Block"
      assert html =~ "block_user"
    end

    test "block button NOT visible for self-DM conversations", %{conn: conn, alice: alice} do
      # Create a self-DM (alice with herself)
      {:ok, self_dm} = Chat.find_or_create_dm(alice.id, alice.id)

      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{self_dm.id}")

      refute html =~ "block_user"
    end

    test "clicking block creates the block, shows flash, and redirects to /chat", %{
      conn: conn,
      alice: alice,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Click the block button (confirm dialog is bypassed in tests)
      lv
      |> element("button[phx-click=\"block_user\"]")
      |> render_click()

      # Should redirect to /chat (welcome screen)
      html = render(lv)
      assert html =~ "Welcome to Slackex"

      # Flash message should confirm the block
      assert render(lv) =~ "has been blocked"

      # Verify the block was actually created in the database
      assert Chat.blocked?(alice.id, bob.id)
    end

    test "after blocking, DM sidebar no longer shows the blocked conversation", %{
      conn: conn,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, initial_html} = live(conn, ~p"/chat/dm/#{dm.id}")

      # Bob's name should be in the sidebar before blocking
      expected_name = bob.display_name || bob.username
      assert initial_html =~ expected_name

      # Block the user
      lv
      |> element("button[phx-click=\"block_user\"]")
      |> render_click()

      # After redirect to /chat, the DM sidebar should no longer show the blocked conversation
      sidebar_html = lv |> element("aside") |> render()
      refute sidebar_html =~ expected_name
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

  describe "message requests sidebar section" do
    setup %{alice: alice} do
      # Create senders with pending DM requests to alice
      sender1 = insert(:user, username: "req_sender1", display_name: "Request Sender One")
      sender2 = insert(:user, username: "req_sender2", display_name: "Request Sender Two")

      req1 =
        insert(:dm_request,
          sender: sender1,
          recipient: alice,
          preview_text: "Hey Alice, I would love to discuss the project with you!",
          status: "pending"
        )

      req2 =
        insert(:dm_request,
          sender: sender2,
          recipient: alice,
          preview_text: String.duplicate("A", 150),
          status: "pending"
        )

      %{sender1: sender1, sender2: sender2, req1: req1, req2: req2}
    end

    test "sidebar shows Message Requests section with pending request count badge", %{
      conn: conn
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Message Requests"
      # Badge showing count of 2 pending requests
      assert html =~ "2"
    end

    test "request shows sender display name and truncated preview text", %{
      conn: conn,
      sender1: sender1
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ sender1.display_name
      # Preview text should be truncated to 100 chars
      assert html =~ "Hey Alice, I would love to discuss the project with you!"
      # The 150-char preview should be truncated
      assert html =~ String.slice(String.duplicate("A", 150), 0, 100)
    end

    test "accept button triggers accept flow and navigates to DM conversation", %{
      conn: conn,
      req1: req1,
      sender1: sender1
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element(~s([phx-click="accept_request"][phx-value-id="#{req1.id}"]))
      |> render_click()

      html = render(lv)
      # Should navigate to the new DM conversation
      expected_name = sender1.display_name || sender1.username
      assert html =~ expected_name
      # Badge count should decrease (1 request remaining)
      assert html =~ "1"
    end

    test "decline button removes request from list without notification", %{
      conn: conn,
      req1: req1,
      sender1: sender1
    } do
      {:ok, lv, html} = live(conn, ~p"/chat")

      # Sender1 visible initially
      assert html =~ sender1.display_name

      lv
      |> element(~s([phx-click="decline_request"][phx-value-id="#{req1.id}"]))
      |> render_click()

      html = render(lv)
      # Sender1's request should be gone
      refute html =~ sender1.display_name
      # Count badge should now show 1
      assert html =~ "1"
    end

    test "block button blocks sender and removes request from list", %{
      conn: conn,
      alice: alice,
      req1: req1,
      sender1: sender1
    } do
      {:ok, lv, html} = live(conn, ~p"/chat")

      assert html =~ sender1.display_name

      lv
      |> element(~s([phx-click="block_request_sender"][phx-value-id="#{req1.id}"]))
      |> render_click()

      html = render(lv)
      # Request should be removed
      refute html =~ sender1.display_name

      # Sender should be blocked in the database
      assert Chat.blocked?(alice.id, sender1.id)
    end

    test "sidebar hides Message Requests section when no pending requests", %{conn: _conn} do
      # Log in as bob who has no pending requests
      bob = insert(:user, username: "bob_no_req")
      bob_conn = build_conn() |> log_in_user(bob)

      {:ok, _lv, html} = live(bob_conn, ~p"/chat")

      refute html =~ "Message Requests"
    end
  end

  describe "PubSub: real-time DM request notifications" do
    test "new dm_request appears in recipient sidebar without page refresh", %{
      conn: conn,
      alice: alice
    } do
      sender = insert(:user, username: "pubsub_sender", display_name: "PubSub Sender")

      {:ok, lv, html} = live(conn, ~p"/chat")

      # Sidebar should NOT show Message Requests yet (alice has no pending requests)
      refute html =~ "PubSub Sender"

      # Simulate PubSub broadcast of a new DM request (as Chat context would)
      request =
        insert(:dm_request,
          sender: sender,
          recipient: alice,
          preview_text: "Hello from PubSub!",
          status: "pending"
        )

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "user:#{alice.id}",
        {:dm_request_new, request}
      )

      # LiveView processes the message; sidebar should now show the request
      html = render(lv)
      assert html =~ "PubSub Sender"
      assert html =~ "Message Requests"
      assert html =~ "1"
    end

    test "accepted dm_request adds conversation to sender DM sidebar in real-time", %{
      conn: _conn
    } do
      # Use fresh users to avoid shared-channel sidebar pollution
      sender = insert(:user, username: "accept_sender", display_name: "Accept Sender")
      recipient = insert(:user, username: "accept_recip", display_name: "Accept Recipient")

      # Log in as sender
      sender_conn = build_conn() |> log_in_user(sender)
      {:ok, sender_lv, sender_html} = live(sender_conn, ~p"/chat")

      # Sender should NOT see recipient in DM sidebar initially
      refute sender_html =~ "Accept Recipient"

      # Create a DM request struct to simulate acceptance
      request =
        insert(:dm_request,
          sender: sender,
          recipient: recipient,
          preview_text: "Hey!",
          status: "accepted"
        )

      # Create the DM conversation that acceptance would produce
      _dm = create_dm_between(sender, recipient)

      # Simulate PubSub broadcast that Chat.accept_dm_request sends to sender
      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "user:#{sender.id}",
        {:dm_request_accepted, request}
      )

      # Sender's sidebar should now show recipient in DM conversations
      html = render(sender_lv)
      assert html =~ "Accept Recipient"
    end

    test "badge count increments on new request via PubSub", %{conn: conn, alice: alice} do
      # Set up alice with one existing request
      sender1 = insert(:user, username: "badge_s1", display_name: "Badge Sender 1")

      insert(:dm_request,
        sender: sender1,
        recipient: alice,
        preview_text: "First request",
        status: "pending"
      )

      {:ok, lv, html} = live(conn, ~p"/chat")
      assert html =~ "1"

      # Broadcast a second request
      sender2 = insert(:user, username: "badge_s2", display_name: "Badge Sender 2")

      request2 =
        insert(:dm_request,
          sender: sender2,
          recipient: alice,
          preview_text: "Second request",
          status: "pending"
        )

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "user:#{alice.id}",
        {:dm_request_new, request2}
      )

      html = render(lv)
      assert html =~ "2"
      assert html =~ "Badge Sender 2"
    end
  end

  describe "NewDmModal routes through create_dm_request for first contact" do
    setup %{alice: _alice, bob: _bob} do
      carol = insert(:user, username: "dm_req_carol", display_name: "DmReq Carol")
      %{carol: carol}
    end

    test "selecting a user with no existing DM creates a dm_request and shows flash", %{
      conn: conn,
      alice: alice,
      carol: carol
    } do
      # Make alice's account old enough to pass the account age check
      Slackex.Repo.update_all(
        from(u in Slackex.Accounts.User, where: u.id == ^alice.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)]
      )

      # Alice and carol share a channel (general from setup) -- join carol
      channel = Chat.get_channel_by_slug!("general")
      Chat.join_channel(carol.id, channel.id)

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Search for carol
      lv
      |> element("#new-dm-search")
      |> render_change(%{"search_query" => "dm_req_carol"})

      # Click on carol
      lv
      |> element("#new-dm-modal [data-user-id=\"#{carol.id}\"]")
      |> render_click()

      # Should show flash about request sent (not navigate to a DM)
      html = render(lv)
      assert html =~ "request sent" or html =~ "Request sent" or html =~ "DM request sent"
    end

    test "selecting a user with existing DM navigates to DM as before", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      # Create existing DM between alice and bob
      _dm = create_dm_between(alice, bob)

      # Make alice's account old enough
      Slackex.Repo.update_all(
        from(u in Slackex.Accounts.User, where: u.id == ^alice.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)]
      )

      {:ok, lv, _html} = live(conn, ~p"/chat/dm/new")

      # Search for bob
      lv
      |> element("#new-dm-search")
      |> render_change(%{"search_query" => "bob"})

      # Click on bob
      lv
      |> element("#new-dm-modal [data-user-id=\"#{bob.id}\"]")
      |> render_click()

      # Should navigate to the existing DM conversation (modal closes)
      html = render(lv)
      refute html =~ "new-dm-modal"
    end
  end

  describe "sidebar online indicators" do
    test "DM list items show green dot for online users", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      # Mark bob as online in Redis
      OnlineTracker.mark_online(bob.id)

      {:ok, _lv, html} = live(conn, ~p"/chat")

      # The avatar for bob in the DM list should have the online indicator
      # Verify the green dot (bg-success span) appears inside the DM list item
      assert html =~ "bg-success"
      # The DM list item for bob should contain the online indicator span
      assert html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s
    end

    test "DM list items do not show green dot for offline users", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      # Do NOT mark bob as online
      {:ok, _lv, html} = live(conn, ~p"/chat")

      # Bob's DM list item should not contain the online indicator
      # The li containing bob's profile user id should not have bg-success
      refute html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s
    end
  end

  describe "real-time presence broadcasts" do
    test "receiving a presence online broadcast adds user to online_user_ids", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      {:ok, lv, html} = live(conn, ~p"/chat")

      # Bob is initially offline — his DM list item should not have the green dot
      refute html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s

      # Simulate a presence broadcast that bob came online
      send(lv.pid, {:presence, :online, bob.id})

      # After the broadcast, bob's DM list item should show the green dot
      html = render(lv)

      assert html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s
    end

    test "receiving a presence offline broadcast removes user from online_user_ids", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      # Mark bob as online so he shows up initially
      OnlineTracker.mark_online(bob.id)

      {:ok, lv, html} = live(conn, ~p"/chat")

      # Bob is initially online — his DM list item should have the green dot
      assert html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s

      # Simulate a presence broadcast that bob went offline
      send(lv.pid, {:presence, :offline, bob.id})

      # After the broadcast, bob's DM list item should no longer have the green dot
      html = render(lv)

      refute html =~
               ~r/<li>.*?data-profile-user-id="#{bob.id}".*?bg-success.*?<\/li>/s
    end

    test "presence online broadcast for unknown user does not crash", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Sending a presence broadcast for a user not in any DM should not crash
      send(lv.pid, {:presence, :online, -1})

      # LiveView should still be alive and rendering
      assert render(lv) =~ "Welcome to Slackex"
    end

    test "user connection broadcasts presence online via PubSub", %{
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      # Subscribe to the presence topic to capture broadcasts
      Phoenix.PubSub.subscribe(Slackex.PubSub, "presence:online")

      # Log bob in and connect — this should trigger a presence broadcast
      bob_conn = build_conn() |> log_in_user(bob)
      {:ok, _lv, _html} = live(bob_conn, ~p"/chat")

      # We should receive the presence online broadcast for bob
      assert_receive {:presence, :online, bob_id}
      assert bob_id == bob.id
    end

    test "user disconnection broadcasts presence offline via PubSub", %{
      alice: alice,
      bob: bob
    } do
      _dm = create_dm_between(alice, bob)

      # Subscribe to the presence topic to capture broadcasts
      Phoenix.PubSub.subscribe(Slackex.PubSub, "presence:online")

      # Log bob in and connect
      bob_conn = build_conn() |> log_in_user(bob)
      {:ok, lv, _html} = live(bob_conn, ~p"/chat")

      # Drain the online broadcast from mount
      assert_receive {:presence, :online, _bob_id}

      # Stop the LiveView to trigger terminate
      GenServer.stop(lv.pid)

      # We should receive the presence offline broadcast for bob
      assert_receive {:presence, :offline, bob_id}
      assert bob_id == bob.id
    end
  end

  describe "user profile card" do
    setup %{alice: alice, bob: bob} do
      %{dm: create_dm_between(alice, bob)}
    end

    # AC1: Clicking a user avatar in the DM sidebar opens a profile card
    test "clicking avatar in DM sidebar opens profile card for that user", %{
      conn: conn,
      bob: bob,
      dm: _dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Click on the avatar area for the DM user in the sidebar
      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "user-profile-card"
      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
      assert html =~ "@#{bob.username}"
    end

    # AC2: Profile card displays display_name with fallback, @username, status, online indicator
    test "profile card shows display_name, falls back to username when nil", %{
      conn: _conn,
      alice: alice
    } do
      # Create a user with no display_name
      no_name = insert(:user, username: "noname_user", display_name: nil)
      _dm = create_dm_between(alice, no_name)

      conn = build_conn() |> log_in_user(alice)
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{no_name.id}\"]")
      |> render_click()

      html = render(lv)
      # Should fall back to username as the display heading
      assert html =~ "noname_user"
      assert html =~ "@noname_user"
    end

    test "profile card shows online indicator when user is online", %{
      conn: conn,
      bob: bob,
      dm: _dm
    } do
      OnlineTracker.mark_online(bob.id)

      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "user-profile-card"
      # Verify user content is displayed in the profile card
      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
      assert html =~ "@#{bob.username}"
      assert html =~ bob.status
      # Online indicator should be present in the profile card
      assert html =~ "badge-success"
      assert html =~ "Online"
    end

    test "profile card shows offline indicator when user is offline", %{
      conn: conn,
      bob: bob,
      dm: _dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "user-profile-card"
      # Verify user content is displayed in the profile card
      expected_name = bob.display_name || bob.username
      assert html =~ expected_name
      assert html =~ "@#{bob.username}"
      assert html =~ bob.status
      # Offline indicator should be present
      assert html =~ "badge-ghost"
      assert html =~ "Offline"
    end

    # AC3: "Send Message" button navigates to existing DM or creates one
    test "Send Message button navigates to DM conversation with that user", %{
      conn: conn,
      bob: bob,
      dm: dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      # Click Send Message in the profile card
      lv
      |> element("#user-profile-card button", "Send Message")
      |> render_click()

      # Should navigate to the DM conversation
      assert_patch(lv, ~p"/chat/dm/#{dm.id}")
    end

    # AC4: "Send Message" button hidden on own profile
    test "Send Message button is hidden when viewing own profile", %{
      conn: conn,
      alice: alice,
      dm: _dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      # Open profile card for current user (alice) via the user footer
      lv
      |> element("[data-profile-user-id=\"#{alice.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "user-profile-card"
      refute html =~ "Send Message"
    end

    # AC5: Profile card closes on outside click or Escape
    test "profile card closes when clicking the backdrop", %{
      conn: conn,
      bob: bob,
      dm: _dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      # Profile card should be open
      html = render(lv)
      assert html =~ "user-profile-card"

      # Click the backdrop to close
      lv
      |> element("#profile-backdrop")
      |> render_click()

      html = render(lv)
      refute html =~ "user-profile-card"
    end

    test "profile card closes when pressing Escape", %{
      conn: conn,
      bob: bob,
      dm: _dm
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv
      |> element("[data-profile-user-id=\"#{bob.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "user-profile-card"

      # Press Escape
      render_keydown(lv, "close_profile", %{"key" => "Escape"})

      html = render(lv)
      refute html =~ "user-profile-card"
    end
  end

  describe "edit profile from sidebar" do
    # AC1: Sidebar user footer shows a settings/edit button next to the logout button
    test "sidebar footer shows edit profile button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")
      assert html =~ "Edit profile"
    end

    # AC2: Clicking the edit button opens a modal with form fields for display_name and status
    test "clicking edit profile button opens modal with form fields", %{conn: conn, alice: alice} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      html = render(lv)
      assert html =~ "edit-profile-modal"
      assert html =~ "Display Name"
      assert html =~ "Status"
      # Form should be pre-filled with current user data
      assert html =~ alice.username
    end

    # AC3: Submitting the form with valid data saves changes and closes the modal
    test "submitting valid profile data saves and closes modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      lv
      |> form("#edit-profile-form", %{
        "profile" => %{"display_name" => "Alice Updated", "status" => "Working hard"}
      })
      |> render_submit()

      html = render(lv)
      # Modal should be closed
      refute html =~ "edit-profile-modal"
      # Updated name should appear in sidebar footer
      assert html =~ "Alice Updated"
    end

    # AC4: Sidebar footer display name updates immediately after successful save
    test "sidebar footer updates display name after save", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      lv
      |> form("#edit-profile-form", %{
        "profile" => %{"display_name" => "New Name", "status" => ""}
      })
      |> render_submit()

      html = render(lv)
      assert html =~ "New Name"
    end

    # AC5: Validation errors display inline in the modal
    test "display_name over 50 chars shows validation error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      long_name = String.duplicate("a", 51)

      html =
        lv
        |> form("#edit-profile-form", %{
          "profile" => %{"display_name" => long_name, "status" => ""}
        })
        |> render_submit()

      # Modal should still be open with error
      assert html =~ "edit-profile-modal"
      assert html =~ "should be at most 50 character(s)"
    end

    test "status over 100 chars shows validation error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      long_status = String.duplicate("b", 101)

      html =
        lv
        |> form("#edit-profile-form", %{
          "profile" => %{"display_name" => "Valid", "status" => long_status}
        })
        |> render_submit()

      # Modal should still be open with error
      assert html =~ "edit-profile-modal"
      assert html =~ "should be at most 100 character(s)"
    end

    # Close modal behaviors
    test "edit profile modal closes on Escape", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()
      assert render(lv) =~ "edit-profile-modal"

      render_keydown(lv, "close_edit_profile", %{"key" => "Escape"})

      refute render(lv) =~ "edit-profile-modal"
    end

    test "edit profile modal closes on backdrop click", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()
      assert render(lv) =~ "edit-profile-modal"

      lv |> element("#edit-profile-backdrop") |> render_click()

      refute render(lv) =~ "edit-profile-modal"
    end

    # Profile update broadcast
    test "saving profile broadcasts update to other users", %{conn: conn, alice: alice} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, "profile:updates")

      {:ok, lv, _html} = live(conn, ~p"/chat")

      lv |> element("button[aria-label=\"Edit profile\"]") |> render_click()

      lv
      |> form("#edit-profile-form", %{
        "profile" => %{"display_name" => "Broadcast Name", "status" => "broadcasting"}
      })
      |> render_submit()

      assert_receive {:profile_updated, updated_user}
      assert updated_user.id == alice.id
      assert updated_user.display_name == "Broadcast Name"
      assert updated_user.status == "broadcasting"
    end
  end

  describe "message editing" do
    setup %{alice: alice, bob: bob, channel: channel} do
      {:ok, msg} = Chat.send_message(channel.id, alice.id, "Original content")
      {:ok, bob_msg} = Chat.send_message(channel.id, bob.id, "Bob's message")
      %{message: msg, bob_message: bob_msg}
    end

    test "edit_message sets editing_message_id for own message", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      lv
      |> element("[phx-click='edit_message'][phx-value-msg-id='#{message.id}']")
      |> render_click()

      # The editing state should be active - an edit form should appear
      html = render(lv)
      assert html =~ "save_edit"
    end

    test "edit_message does not allow editing another user's message", %{
      conn: conn,
      channel: channel,
      bob_message: bob_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Directly push the event with bob's message id
      render_click(lv, "edit_message", %{"msg-id" => "#{bob_message.id}"})

      html = render(lv)
      # Should NOT show edit form
      refute html =~ "save_edit"
    end

    test "cancel_edit clears editing state", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(lv, "edit_message", %{"msg-id" => "#{message.id}"})
      assert render(lv) =~ "save_edit"

      render_click(lv, "cancel_edit", %{})
      refute render(lv) =~ "save_edit"
    end

    test "inline edit form shows textarea pre-filled with original content and Save/Cancel buttons",
         %{
           conn: conn,
           channel: channel,
           message: message
         } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(lv, "edit_message", %{"msg-id" => "#{message.id}"})

      html = render(lv)
      # Textarea should be pre-filled with the original content
      assert html =~ "edit-input-#{message.id}"
      assert html =~ "Original content"
      # Save and Cancel buttons should be visible
      assert html =~ "Save"
      assert html =~ "Cancel"
    end

    test "inline edit form replaces message content area", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, html_before} = live(conn, ~p"/chat/#{channel.slug}")

      # Before editing, message shows as plain text (no textarea)
      refute html_before =~ "edit-input-#{message.id}"

      render_click(lv, "edit_message", %{"msg-id" => "#{message.id}"})

      html_after = render(lv)
      # After editing, textarea appears
      assert html_after =~ "edit-input-#{message.id}"
      # The message content should be in the textarea, not as plain paragraph text
      assert html_after =~ "textarea"
    end

    test "save_edit updates message content and clears editing state", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(lv, "edit_message", %{"msg-id" => "#{message.id}"})

      render_click(lv, "save_edit", %{"content" => "Updated content"})

      html = render(lv)
      assert html =~ "Updated content"
      refute html =~ "save_edit"
    end

    test "save_edit shows flash on error for unauthorized edit", %{
      conn: conn,
      channel: channel,
      bob_message: bob_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Force editing_message_id by directly setting it (simulating a tampered client)
      # We send save_edit with bob's message id - the Messaging layer will reject it
      render_click(lv, "save_edit", %{
        "msg-id" => "#{bob_message.id}",
        "content" => "Hacked content"
      })

      html = render(lv)
      assert html =~ "Could not edit message"
    end

    test "message.edited envelope updates message in stream for all connected users", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      edited_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      envelope =
        Envelope.wrap("message.edited", {:channel, channel.id}, %{
          id: message.id,
          content: "Edited by broadcast",
          edited_at: edited_at
        })

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "channel:#{channel.id}",
        {:envelope, envelope}
      )

      html = render(lv)
      assert html =~ "Edited by broadcast"
      assert html =~ "edited"
    end
  end

  describe "message deletion" do
    setup %{alice: alice, bob: bob, channel: channel} do
      {:ok, msg} = Chat.send_message(channel.id, alice.id, "Delete me")
      {:ok, bob_msg} = Chat.send_message(channel.id, bob.id, "Bob delete me")
      %{message: msg, bob_message: bob_msg}
    end

    test "delete_message removes own message and shows deleted placeholder", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(lv, "delete_message", %{"msg-id" => "#{message.id}"})

      html = render(lv)

      assert html =~ "This message has been deleted"
      # Bob's message still shows its delete button with title="Delete message",
      # so we check the deleted message's content area specifically
      refute html =~ ">Delete me<"
    end

    test "delete_message shows flash on error for unauthorized deletion", %{
      conn: conn,
      channel: channel,
      bob_message: bob_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # alice is channel owner so she CAN delete bob's message in a channel.
      # We need a scenario where deletion fails. Let's delete it once and try again.
      render_click(lv, "delete_message", %{"msg-id" => "#{bob_message.id}"})

      # Try deleting a non-existent message
      render_click(lv, "delete_message", %{"msg-id" => "999999999"})

      html = render(lv)
      assert html =~ "Could not delete message"
    end

    test "message.deleted envelope updates message in stream for all connected users", %{
      conn: conn,
      channel: channel,
      message: message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      deleted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      envelope =
        Envelope.wrap("message.deleted", {:channel, channel.id}, %{
          id: message.id,
          deleted_at: deleted_at
        })

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "channel:#{channel.id}",
        {:envelope, envelope}
      )

      html = render(lv)
      assert html =~ "This message has been deleted"
      # Bob's message still has title="Delete message" which contains "Delete me" substring,
      # so check the deleted message's content area specifically
      refute html =~ ">Delete me<"
    end
  end

  describe "message editing in DMs" do
    setup %{alice: alice, bob: bob} do
      dm = create_dm_between(alice, bob)
      {:ok, msg} = Chat.send_dm(dm.id, alice.id, "DM to edit")
      %{dm: dm, dm_message: msg}
    end

    test "edit and save in DM updates message content", %{
      conn: conn,
      dm: dm,
      dm_message: dm_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      render_click(lv, "edit_message", %{"msg-id" => "#{dm_message.id}"})
      assert render(lv) =~ "save_edit"

      render_click(lv, "save_edit", %{"content" => "DM updated content"})

      html = render(lv)
      assert html =~ "DM updated content"
      refute html =~ "save_edit"
    end

    test "message.edited envelope in DM updates stream", %{
      conn: conn,
      dm: dm,
      dm_message: dm_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      edited_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      envelope =
        Envelope.wrap("message.edited", {:dm, dm.id}, %{
          id: dm_message.id,
          content: "DM edited by broadcast",
          edited_at: edited_at
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      html = render(lv)
      assert html =~ "DM edited by broadcast"
    end

    test "message.deleted envelope in DM updates stream", %{
      conn: conn,
      dm: dm,
      dm_message: dm_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/dm/#{dm.id}")

      deleted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      envelope =
        Envelope.wrap("message.deleted", {:dm, dm.id}, %{
          id: dm_message.id,
          deleted_at: deleted_at
        })

      Phoenix.PubSub.broadcast(Slackex.PubSub, "dm:#{dm.id}", {:envelope, envelope})

      html = render(lv)
      refute html =~ "DM to edit"
      assert html =~ "deleted"
    end
  end

  describe "message bubble hover actions and indicators" do
    setup %{alice: alice, bob: bob, channel: channel} do
      {:ok, alice_msg} = Chat.send_message(channel.id, alice.id, "Alice message")
      {:ok, bob_msg} = Chat.send_message(channel.id, bob.id, "Bob message")
      %{alice_message: alice_msg, bob_message: bob_msg}
    end

    test "own message shows Edit and Delete buttons", %{
      conn: conn,
      channel: channel,
      alice_message: alice_message
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Alice should see edit and delete on her own message
      assert html =~ "phx-click=\"edit_message\""
      assert html =~ "phx-value-msg-id=\"#{alice_message.id}\""
      assert html =~ "phx-click=\"delete_message\""
    end

    test "channel owner sees Delete button on other user's messages", %{
      conn: conn,
      channel: channel,
      bob_message: bob_message
    } do
      # alice is channel owner, so she should see Delete on bob's message
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # There should be a delete button targeting bob's message
      assert html =~ "phx-click=\"delete_message\""
      assert html =~ "phx-value-msg-id=\"#{bob_message.id}\""
    end

    test "channel owner does NOT see Edit button on other user's messages", %{
      conn: conn,
      channel: channel,
      bob_message: bob_message
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      # There should NOT be an edit button targeting bob's message
      # Edit buttons should only exist for alice's own messages
      refute html =~ "phx-click=\"edit_message\" phx-value-msg-id=\"#{bob_message.id}\""
    end

    test "delete button has data-confirm attribute", %{
      conn: conn,
      channel: channel
    } do
      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "data-confirm=\"Are you sure you want to delete this message?\""
    end

    test "edited message shows (edited) indicator", %{
      conn: conn,
      channel: channel,
      alice_message: alice_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Edit the message to set edited_at
      render_click(lv, "edit_message", %{"msg-id" => "#{alice_message.id}"})
      render_click(lv, "save_edit", %{"content" => "Updated content"})

      html = render(lv)
      assert html =~ "(edited)"
    end

    test "deleted message shows placeholder with no hover actions", %{
      conn: conn,
      channel: channel,
      alice_message: alice_message
    } do
      {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(lv, "delete_message", %{"msg-id" => "#{alice_message.id}"})

      html = render(lv)
      assert html =~ "This message has been deleted"

      # No edit or delete buttons should target the deleted message
      refute html =~ "phx-click=\"edit_message\" phx-value-msg-id=\"#{alice_message.id}\""
      refute html =~ "phx-click=\"delete_message\" phx-value-msg-id=\"#{alice_message.id}\""
    end

    test "report button appears for DM messages from other users (no regression)", %{
      conn: conn,
      alice: alice,
      bob: bob
    } do
      dm = create_dm_between(alice, bob)
      {:ok, _bob_dm_msg} = Chat.send_dm(dm.id, bob.id, "Bob DM content")

      {:ok, _lv, html} = live(conn, ~p"/chat/dm/#{dm.id}")

      assert html =~ "report_message"
    end
  end
end
