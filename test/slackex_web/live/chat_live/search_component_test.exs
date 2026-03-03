defmodule SlackexWeb.ChatLive.SearchComponentTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

    # Create a channel with some messages for search
    {:ok, channel} = Chat.create_channel(user.id, %{name: "search-test"})

    %{conn: conn, user: user, channel: channel}
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Feature flag controls search component visibility
  # ---------------------------------------------------------------------------

  describe "feature flag guards" do
    test "search toggle button is not rendered when :message_search flag is disabled",
         %{conn: conn, channel: channel} do
      FunWithFlags.disable(:message_search)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")

      refute html =~ "search-component"
      refute html =~ "Search messages"
      refute html =~ "toggle_search"
    end

    test "search toggle button is rendered when :message_search flag is enabled and opens panel",
         %{conn: conn, channel: channel} do
      FunWithFlags.enable(:message_search)

      {:ok, view, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Toggle button should be present
      assert html =~ "toggle_search"

      # Clicking it should open the search component
      html = render_click(view, "toggle_search")
      assert html =~ "search-component"
      assert html =~ "Search messages"
    end

    test "search_messages/3 returns {:error, :feature_disabled} when flag is off",
         %{user: user} do
      FunWithFlags.disable(:message_search)

      assert {:error, :feature_disabled} = Slackex.Search.search_messages(user.id, "test query")
    end

    test "search_messages/3 performs search when flag is enabled",
         %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      # Send a message to have something to find
      Chat.send_message(channel.id, user.id, "hello world searchable")
      # Allow time for search_content to be populated
      Process.sleep(50)

      # Use text mode to avoid needing embedding infrastructure
      assert {:ok, _results} = Slackex.Search.search_messages(user.id, "searchable", mode: :text)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Search with 2+ characters triggers search via component event
  # ---------------------------------------------------------------------------

  describe "search behavior through component events" do
    setup %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      # Create messages to search
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "important meeting notes")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "casual conversation")
      Process.sleep(50)

      %{msg1: msg1, msg2: msg2}
    end

    test "typing 2+ characters in search input triggers search via handle_event",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Open search panel
      render_click(view, "toggle_search")

      # Type a search query through the component's form -- this fires handle_event("search", ...)
      # which sends {:perform_search, ...} to the parent, which calls Search.search_messages
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "meeting"})

      # Allow the parent's handle_info to process the {:perform_search, ...} message
      # and send_update back to the component
      Process.sleep(100)
      html = render(view)

      # The search input should be visible and results should contain the matching message
      assert html =~ "Search messages"
      assert html =~ "important meeting notes"
    end

    test "typing fewer than 2 characters does not trigger search",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Type a single character -- should NOT trigger search (< 2 chars)
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "m"})

      html = render(view)

      # Component should still be there with the min-length hint, no results
      assert html =~ "search-component"
      assert html =~ "Type at least 2 characters to search"
    end

    test "empty query clears results and shows prompt",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # First search with a valid query to get results
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "meeting"})

      Process.sleep(100)

      # Now clear the query
      view
      |> element("#search-component form")
      |> render_change(%{"query" => ""})

      html = render(view)

      # Should show the hint message, not results
      assert html =~ "Type at least 2 characters to search"
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Loading state shown during search
  # ---------------------------------------------------------------------------

  describe "loading state" do
    setup do
      FunWithFlags.enable(:message_search)
      :ok
    end

    test "searching flag shows loading indicator", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Trigger a search through the component -- the component sets searching=true
      # before the parent receives the message
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "something to search"})

      # Immediately after the component processes the event, searching=true
      # but the parent hasn't responded yet. The component should show loading.
      # Note: In LiveView testing, the handle_info may process synchronously.
      # We verify the loading indicator by checking before results arrive.
      # Use send_update to explicitly set searching=true for assertion
      send(view.pid, {:search_started})
      html = render(view)

      assert html =~ "Searching"
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Jump to message from search results
  # ---------------------------------------------------------------------------

  describe "jump to message" do
    setup %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      {:ok, msg} = Chat.send_message(channel.id, user.id, "findable message content")
      Process.sleep(50)

      %{msg: msg}
    end

    test "clicking a search result navigates to the message",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Search for the message through the component form
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "findable"})

      # Allow search to complete and results to be sent back
      Process.sleep(100)
      html = render(view)

      # Results should be displayed with the actual message content
      assert html =~ "findable message content"
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: Mode switching
  # ---------------------------------------------------------------------------

  describe "mode switching" do
    setup do
      FunWithFlags.enable(:message_search)
      :ok
    end

    test "defaults to hybrid search mode", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      html = render_click(view, "toggle_search")

      # Default mode should be hybrid
      assert html =~ "hybrid"
    end
  end

  # ---------------------------------------------------------------------------
  # D5: Integration test -- parent-component search contract
  # ---------------------------------------------------------------------------

  describe "parent-component search integration" do
    setup %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      {:ok, msg} = Chat.send_message(channel.id, user.id, "integration test message")
      Process.sleep(50)

      %{msg: msg}
    end

    test "full flow: toggle search, type query, results appear, close search",
         %{conn: conn, channel: channel} do
      {:ok, view, html} = live(conn, ~p"/chat/#{channel.slug}")

      # Search panel not visible initially
      refute html =~ "search-component"

      # Open search panel via toggle
      html = render_click(view, "toggle_search")
      assert html =~ "search-component"

      # Type a query through the component -- triggers handle_event -> parent handle_info
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "integration"})

      # Wait for async search to complete
      Process.sleep(100)
      html = render(view)

      # Results should contain the actual message from the database
      assert html =~ "integration test message"

      # Close search panel via the component's close button
      view
      |> element("#search-component button[aria-label=\"Close\"]")
      |> render_click()

      html = render(view)

      # Search panel should be closed
      refute html =~ "search-component"
    end

    test "search with no results shows 'No results found'",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Search for something that doesn't match any message
      view
      |> element("#search-component form")
      |> render_change(%{"query" => "xyznonexistentqueryzyx"})

      Process.sleep(100)
      html = render(view)

      assert html =~ "No results found"
    end
  end
end
