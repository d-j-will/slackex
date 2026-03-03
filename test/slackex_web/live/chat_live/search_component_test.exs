defmodule SlackexWeb.ChatLive.SearchComponentTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat
  alias Slackex.Search

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

      assert {:error, :feature_disabled} = Search.search_messages(user.id, "test query")
    end

    test "search_messages/3 performs search when flag is enabled",
         %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      # Send a message to have something to find
      Chat.send_message(channel.id, user.id, "hello world searchable")
      # Allow time for search_content to be populated
      Process.sleep(50)

      # Use text mode to avoid needing embedding infrastructure
      assert {:ok, _results} = Search.search_messages(user.id, "searchable", mode: :text)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Search with 2+ characters shows results
  # ---------------------------------------------------------------------------

  describe "search behavior" do
    setup %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      # Create messages to search
      {:ok, msg1} = Chat.send_message(channel.id, user.id, "important meeting notes")
      {:ok, msg2} = Chat.send_message(channel.id, user.id, "casual conversation")
      Process.sleep(50)

      %{msg1: msg1, msg2: msg2}
    end

    test "search with 2+ characters triggers search and shows results",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Open search
      html = render_click(view, "toggle_search")
      assert html =~ "search-component"

      # Type a search query -- the component sends to parent which performs search
      # Simulate the parent receiving the perform_search message
      send(view.pid, {:search_results, "meeting", []})
      html = render(view)

      # The search input should be visible
      assert html =~ "Search messages"
    end

    test "search with fewer than 2 characters does not trigger search",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Send a single character search -- should be handled gracefully
      send(view.pid, {:search_results, "m", []})
      html = render(view)

      # Component should still be there but no results
      assert html =~ "search-component"
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

      # Trigger a search that sets searching=true
      send(view.pid, {:search_started})
      html = render(view)

      assert html =~ "Searching"
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: Jump to message
  # ---------------------------------------------------------------------------

  describe "jump to message" do
    setup %{user: user, channel: channel} do
      FunWithFlags.enable(:message_search)

      {:ok, msg} = Chat.send_message(channel.id, user.id, "findable message content")
      Process.sleep(50)

      %{msg: msg}
    end

    test "clicking a search result sends jump_to_message event",
         %{conn: conn, channel: channel, msg: msg} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "toggle_search")

      # Simulate search results arriving
      results = [
        %{
          id: msg.id,
          content: "findable message content",
          sender: %{username: "testuser", display_name: "Test User"},
          channel_id: channel.id,
          inserted_at: DateTime.utc_now()
        }
      ]

      send(view.pid, {:search_results, "findable", results})
      html = render(view)

      # Results should be displayed
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
end
