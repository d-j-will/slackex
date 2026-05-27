defmodule SlackexWeb.ChatLive.E2ETest do
  @moduledoc """
  End-to-end tests verifying full user flows across multiple LiveView sessions.

  Tagged :e2e — excluded from the default test run, run with:
    mix test --include e2e
  """
  use SlackexWeb.ConnCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  import Slackex.TestFactory

  alias Slackex.Chat
  alias Slackex.Links.LinkPreview
  alias Slackex.Messaging
  alias Slackex.Messaging.Envelope
  alias Slackex.Repo

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

  describe "link preview pipeline" do
    test "pipeline:events → LinkPreviewWorker runs → preview persisted → LiveView updates via PubSub",
         %{conn: conn} do
      # Stub MetadataParser HTTP for this test only — avoids real network calls.
      # Uses a module plug (not Req.Test ownership) so it works across globally
      # supervised GenServer processes like LinkPreviewListener.
      Application.put_env(:slackex, :metadata_parser_req_options,
        plug: Slackex.Test.MetadataParserStub
      )

      on_exit(fn ->
        Application.delete_env(:slackex, :metadata_parser_req_options)
      end)

      #
      # Full pipeline path proven:
      #   pipeline:events → LinkPreviewListener → LinkPreviewWorker (inline Oban)
      #   → MetadataParser (stubbed HTTP) → LinkPreview record
      #   → link_previews:{id} PubSub → LiveView re-render.
      alice = insert(:user)
      channel = insert(:channel) |> with_subscription(alice)

      # Insert the message directly — bypasses the async ChannelServer batch writer.
      message =
        insert(:message,
          content: "Check out https://example.com for details",
          channel: channel,
          sender: alice
        )

      # Mount the LiveView on the channel so it subscribes to channel PubSub.
      alice_conn = log_in_user(conn, alice)
      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat/#{channel.slug}")

      # Broadcast a message.new envelope on the channel topic. The LiveView handles
      # this in handle_info({:envelope, %{event: "message.new", ...}}) and subscribes
      # to "link_previews:{message.id}" — required for the re-render assertion below.
      envelope =
        Envelope.wrap(
          "message.new",
          {:channel, channel.id},
          Map.merge(message, %{sender: alice})
        )

      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "channel:#{channel.id}",
        {:envelope, envelope}
      )

      # Give the LiveView time to process the envelope and subscribe to the preview topic.
      assert_eventually(fn ->
        render(alice_view) =~ "https://example.com"
      end)

      # Broadcast pipeline:events to the global LinkPreviewListener — proves
      # the full producer → consumer wiring exists.
      Phoenix.PubSub.broadcast(
        Slackex.PubSub,
        "pipeline:events",
        {:messages_persisted, [message.id]}
      )

      # Wait for the LinkPreviewListener GenServer to finish processing the event.
      # :sys.get_state/1 blocks until the GenServer's mailbox is drained.
      listener_pid = Process.whereis(Slackex.Links.LinkPreviewListener)
      if listener_pid, do: :sys.get_state(listener_pid, 2_000)

      # The LinkPreview record must be persisted with status "fetched"
      preview = Repo.get_by!(LinkPreview, message_id: message.id)
      assert preview.status == "fetched"
      assert preview.url == "https://example.com"
      assert preview.title == "Test Page Title"

      # The LiveView must receive the {:link_previews_ready, ...} PubSub broadcast
      # and re-render with preview data — verifying the full consumer wiring.
      assert_eventually(fn ->
        render(alice_view) =~ "Test Page Title"
      end)
    end
  end

  describe "thread dual broadcast" do
    test "reply triggers channel broadcast (reply_count_updated) and thread topic broadcast", %{
      conn: conn
    } do
      alice = insert(:user)
      bob = insert(:user)
      channel = insert(:channel) |> with_subscription(alice) |> with_subscription(bob)

      # Insert the parent message directly so it is immediately visible in the DB
      # (bypasses the async ChannelServer batch writer).
      parent_message = insert(:message, channel: channel, sender: alice)

      # Mount Alice's LiveView — she will receive the channel-topic broadcasts.
      alice_conn = log_in_user(conn, alice)
      {:ok, alice_view, _html} = live(alice_conn, ~p"/chat/#{channel.slug}")

      # Subscribe the test process directly to the thread topic so we can assert
      # the thread.reply broadcast arrives without opening the thread panel UI.
      Phoenix.PubSub.subscribe(Slackex.PubSub, "thread:#{parent_message.id}")

      # Bob sends a reply via the Messaging facade — this proves the full
      # producer path (send_reply → dual broadcast) rather than faking an event.
      assert {:ok, _reply} =
               Messaging.send_reply(channel.id, :channel, bob.id, parent_message.id, "hey alice!")

      # 1. Channel topic broadcast: message.reply_count_updated causes the LiveView
      #    to stream-insert the updated parent, which renders "1 reply".
      assert_eventually(fn ->
        render(alice_view) =~ "1 reply"
      end)

      # 2. Thread topic broadcast: the test process receives {:envelope, thread_envelope}
      #    on "thread:#{parent_message.id}" — proving the thread topic wiring exists.
      assert_receive {:envelope, %{event: "thread.reply", payload: payload}}, 5_000
      assert payload.parent_message_id == parent_message.id
      assert payload.content == "hey alice!"
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
