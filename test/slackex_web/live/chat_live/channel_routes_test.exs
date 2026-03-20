defmodule SlackexWeb.ChatLive.ChannelRoutesTest do
  @moduledoc """
  Acceptance tests for channel creation, browse, and join/leave routes.
  Verifies new routes resolve correctly without being caught by :slug,
  and that existing routes continue to work.
  """
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Chat

  setup %{conn: conn} do
    Redix.command!(:redix_0, ["FLUSHDB"])

    user = insert(:user, username: "routeuser", display_name: "Route User")
    conn = log_in_user(conn, user)

    %{conn: conn, user: user}
  end

  # ---------------------------------------------------------------------------
  # AC1: /chat/channels/new resolves to :create_channel
  # ---------------------------------------------------------------------------

  describe "/chat/channels/new route" do
    test "resolves to :create_channel action without crashing", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/chat/channels/new")

      assert html =~ "Tenun"
      assert lv |> element("div") |> has_element?()
    end

    test "sets page_title for create channel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      assert page_title(lv) =~ "Create Channel"
    end
  end

  # ---------------------------------------------------------------------------
  # AC2: /chat/channels/browse resolves to :browse_channels
  # ---------------------------------------------------------------------------

  describe "/chat/channels/browse route" do
    test "resolves to :browse_channels action without crashing", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/chat/channels/browse")

      assert html =~ "Tenun"
      assert lv |> element("div") |> has_element?()
    end

    test "sets page_title for browse channels", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      assert page_title(lv) =~ "Browse Channels"
    end
  end

  # ---------------------------------------------------------------------------
  # AC3: Existing routes still work
  # ---------------------------------------------------------------------------

  describe "existing routes remain functional" do
    test "/chat still works as :index", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Welcome to Tenun"
    end

    test "/chat/dm/new still works as :new_dm", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat/dm/new")

      assert html =~ "New Message"
    end

    test "/chat/:slug still works for channel slugs", %{conn: conn, user: user} do
      {:ok, channel} =
        Chat.create_channel(user.id, %{name: "general", description: "General chat"})

      {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")

      assert html =~ "#general"
    end
  end

  # ---------------------------------------------------------------------------
  # AC4: Navigating to new routes does not crash the LiveView
  # ---------------------------------------------------------------------------

  describe "navigation between routes does not crash" do
    test "patch from /chat to /chat/channels/new", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      html = render_patch(lv, ~p"/chat/channels/new")

      assert html =~ "Tenun"
    end

    test "patch from /chat to /chat/channels/browse", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat")

      html = render_patch(lv, ~p"/chat/channels/browse")

      assert html =~ "Tenun"
    end

    test "patch from /chat/channels/new back to /chat", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

      html = render_patch(lv, ~p"/chat")

      assert html =~ "Welcome to Tenun"
    end

    test "patch from /chat/channels/browse back to /chat", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

      html = render_patch(lv, ~p"/chat")

      assert html =~ "Welcome to Tenun"
    end
  end
end
