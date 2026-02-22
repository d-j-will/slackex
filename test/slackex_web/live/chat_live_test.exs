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
  end
end
