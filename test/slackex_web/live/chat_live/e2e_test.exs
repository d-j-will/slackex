defmodule SlackexWeb.ChatLive.E2ETest do
  @moduledoc """
  End-to-end tests verifying full user flows across multiple LiveView sessions.

  Tagged :e2e — excluded from the default test run, run with:
    mix test --include e2e
  """
  use SlackexWeb.ConnCase, async: false

  import Slackex.Factory

  alias Slackex.Chat

  @moduletag :e2e

  describe "channel messaging flow" do
    test "message sent by Alice appears in Bob's LiveView via PubSub", %{conn: conn} do
      alice = insert(:user)
      bob = insert(:user)
      channel = insert(:channel) |> with_subscription(alice) |> with_subscription(bob)

      alice_conn = log_in_user(conn, alice)
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)

      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat/#{channel.slug}")
      {:ok, bob_view, _html} = live(bob_conn, ~p"/chat/#{channel.slug}")

      # Alice sends a message
      alice_view
      |> form("#message-form", %{message: %{content: "hello from alice"}})
      |> render_submit()

      # Wait for ChannelServer batch flush (~2s interval) + PubSub propagation
      assert_eventually(fn ->
        render(bob_view) =~ "hello from alice"
      end)
    end
  end

  describe "DM request flow" do
    test "Alice's DM request to Bob (shared_channels preference, shared channel) is persisted and Bob's LiveView updates via PubSub",
         _context do
      # Alice must be >= 24 hours old (account age gate) and >= 7 days old (new-account
      # shared-channel gate) so the only remaining check is Bob's dm_preference.
      alice = insert_user_with_age_days(8)

      # Bob allows DMs only from users who share a channel with him.
      bob = insert(:user, dm_preference: "shared_channels")

      # Alice and Bob share a channel — this satisfies Bob's dm_preference check,
      # so create_dm_request returns {:ok, %DMRequest{}} rather than an error.
      _channel = insert(:channel) |> with_subscription(alice) |> with_subscription(bob)

      # Mount Bob's LiveView before the request so it is subscribed to "user:<bob.id>"
      # and will receive the {:dm_request_new, request} PubSub broadcast.
      bob_conn = Phoenix.ConnTest.build_conn() |> log_in_user(bob)
      {:ok, bob_view, _html} = live(bob_conn, ~p"/chat")

      # Alice sends a DM request via the context layer — proves the full
      # producer path exists (not just the handler in isolation).
      assert {:ok, %Slackex.Chat.DMRequest{status: "pending"}} =
               Chat.create_dm_request(alice.id, bob.id, "Hey Bob!")

      # The request must be persisted in the database.
      pending = Chat.list_pending_requests_for_user(bob.id)
      assert length(pending) == 1
      [request] = pending
      assert request.sender_id == alice.id
      assert request.recipient_id == bob.id
      assert request.status == "pending"

      # Bob's LiveView receives the {:dm_request_new, ...} PubSub broadcast and
      # shows the "Message Requests" section — verifying the full producer → consumer wiring.
      assert_eventually(fn ->
        render(bob_view) =~ "Message Requests"
      end)
    end
  end

  # Poll helper — retries assertion for up to timeout_ms
  defp assert_eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 100) do
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
