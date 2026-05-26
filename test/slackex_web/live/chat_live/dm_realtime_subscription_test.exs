defmodule SlackexWeb.ChatLive.DmRealtimeSubscriptionTest do
  @moduledoc """
  Regression tests for the "first message in a freshly-created DM" bug.

  Symptom: the first message sent in a brand-new DM never reaches the recipient
  in real time; only the 2nd+ messages do (after the recipient opens the DM and
  is finally subscribed).

  Root cause: when a DM is created, both participants receive
  `{:dm_conversation_new, dm}` on their `user:<id>` topic. The recipient's
  handler refreshed the sidebar but never subscribed to the `dm:<id>` PubSub
  topic, so the first `message.new` broadcast was dropped.

  These tests exercise the full producer -> consumer path (no faked upstream
  events): `Chat.find_or_create_dm/2` is the real producer of
  `{:dm_conversation_new, ...}` and `Messaging.send_dm/3` is the real producer
  of `message.new`.
  """
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slackex.TestFactory

  alias Slackex.Chat
  alias Slackex.Messaging

  describe "recipient subscription on new DM" do
    test "first message in a freshly-created DM reaches a recipient who is already online",
         _context do
      alice = insert(:user)
      bob = insert(:user)

      # Bob is online, viewing the chat home — he has no DMs yet. His LiveView is
      # subscribed to "user:<bob.id>" (mount) but NOT to any "dm:<id>" topic.
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)
      {:ok, bob_view, _html} = live(bob_conn, ~p"/chat")

      # Alice creates the DM. This is the real producer of {:dm_conversation_new, dm}
      # broadcast to both users' "user:<id>" topics.
      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Synchronise: wait until Bob's LiveView has processed {:dm_conversation_new}
      # (the new DM now appears in his sidebar). With the fix, processing this event
      # also subscribes Bob to "dm:<dm.id>", so the next message will reach him.
      assert_eventually(fn ->
        render(bob_view) =~ "/chat/dm/#{dm.id}"
      end)

      # Alice sends the FIRST message via the real send path (ChannelServer ->
      # message.new broadcast on "dm:<dm.id>").
      {:ok, _message} = Messaging.send_dm(dm.id, alice.id, "first-message-ping")

      # The message must reach Bob in real time. Bob is not viewing the DM, so it
      # surfaces as an unread count increment for that conversation.
      assert_eventually(fn ->
        dm_unread_count(bob_view, dm.id) >= 1
      end)
    end
  end

  describe "sender sees their own first message in a freshly-entered DM" do
    test "sender's own first message appears in their stream", %{conn: conn} do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

      # Alice enters the freshly-created DM (mount + handle_params(:dm) ->
      # enter_dm -> subscribe_dm) and immediately sends.
      alice_conn = log_in_user(conn, alice)
      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat/dm/#{dm.id}")

      alice_view
      |> form("#message-form", %{message: %{content: "sender-sees-this"}})
      |> render_submit()

      # The sender does not optimistically insert; she sees her own message only
      # via the message.new broadcast loopback. It must appear in her stream.
      assert_eventually(fn ->
        render(alice_view) =~ "sender-sees-this"
      end)
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp dm_unread_count(view, dm_id) do
    view.pid
    |> :sys.get_state()
    |> get_in([Access.key(:socket), Access.key(:assigns), :unread_counts, :dm_counts])
    |> Kernel.||(%{})
    |> Map.get(dm_id, 0)
  end

  defp assert_eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Assertion did not become true within timeout")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end
end
