defmodule Slackex.Andon.ListenerTest do
  @moduledoc """
  End-to-end for the relay's inbound path: a real channel message becomes the
  right domain event (posted through the stubbed service seam), and response
  commands are rendered as in-thread bot replies. Drives the actual
  `message.new` PubSub flow through a dedicated listener.

  async: false — ChannelServer + the listener need shared sandbox access.
  """
  use Slackex.DataCase, async: false

  alias Slackex.Andon
  alias Slackex.Chat
  alias Slackex.Messaging

  setup do
    user = insert(:user, username: "puller-anna")
    channel = insert(:channel, creator: user, is_private: false)
    bot = Andon.bot_user()

    {:ok, _} = Chat.Channels.join_channel(user.id, channel.id)
    {:ok, _} = Chat.Channels.join_channel(bot.id, channel.id)

    # Sandbox rollback clears the flag row; no DB work in on_exit (house rule).
    FunWithFlags.enable(:andon_relay)
    Application.put_env(:slackex, :andon_service_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:slackex, :andon_service_test_pid)
      Application.delete_env(:slackex, :andon_service_stub_response)
    end)

    start_supervised!(
      {Andon.Listener,
       name: :listener_under_test,
       channels: [channel.id],
       bot_id: bot.id,
       subscribe_on_boot: false}
    )

    %{user: user, channel: channel, bot: bot}
  end

  # The listener's input boundary is the `message.new` PubSub envelope. We
  # persist the message synchronously (so the relay's in-thread replies find the
  # parent row) and broadcast the same envelope ChannelServer emits, rather than
  # go through the async ChannelServer persistence path (which does not write
  # within the sandbox). The payload carries exactly the fields the relay reads.
  defp post_message(channel, user, text) do
    {:ok, message} = Chat.Messages.send_message(channel.id, user.id, text)

    broadcast_new(channel.id, %{
      id: message.id,
      content: text,
      sender_id: user.id,
      channel_id: channel.id
    })

    message
  end

  defp post_reply(channel, user, parent_id, text) do
    {:ok, reply} = Chat.send_reply(channel.id, user.id, parent_id, text)

    broadcast_new(channel.id, %{
      id: reply.id,
      content: text,
      sender_id: user.id,
      channel_id: channel.id,
      parent_message_id: parent_id
    })

    reply
  end

  defp broadcast_new(channel_id, payload) do
    envelope = Messaging.Envelope.wrap("message.new", {:channel, channel_id}, payload)
    Phoenix.PubSub.broadcast(Slackex.PubSub, "channel:#{channel_id}", {:envelope, envelope})
  end

  # Polls an assertion function until it stops raising, or fails after ~1s.
  defp eventually(fun, retries \\ 50) do
    fun.()
  rescue
    e ->
      if retries > 0 do
        Process.sleep(20)
        eventually(fun, retries - 1)
      else
        reraise(e, __STACKTRACE__)
      end
  end

  describe "a top-level pull message" do
    test "becomes a pull_created event with a message-derived event_id and origin", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: defect the build is red on main")

      assert_receive {:andon_event_posted, event}, 1_000

      assert event["event"] == "pull_created"
      assert event["event_id"] == "slackex-#{message.id}"
      assert event["class"] == "defect"
      assert event["sentence"] == "the build is red on main"
      assert event["puller"] == %{"relay" => "slackex", "token" => to_string(user.id)}

      assert event["origin"] == %{
               "relay" => "slackex",
               "channel" => to_string(channel.id),
               # top-level: the thread is the message's own id
               "thread" => to_string(message.id),
               "message" => to_string(message.id)
             }
    end
  end

  describe "an invalid pull" do
    test "posts an in-thread correction and sends NO event", %{channel: channel, user: user} do
      message = post_message(channel, user, "pull: severity-1 the build is red on main")

      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.content =~ "pull:"
        assert reply.sender_id == Andon.bot_user().id
      end)
    end
  end

  describe "ordinary channel traffic" do
    test "a non-pull top-level message produces no event and no reply", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "just chatting about lunch")

      refute_receive {:andon_event_posted, _}, 300
      assert Chat.list_thread(message.id) == []
    end

    test "the bot's own messages never trigger an event (no loops)", %{
      channel: channel,
      bot: bot
    } do
      post_message(channel, bot, "pull: defect this should be ignored from the bot")

      refute_receive {:andon_event_posted, _}, 300
    end
  end

  describe "in-thread affordances (replies only)" do
    test "`ack` in a thread becomes an ack event with the actor", %{channel: channel, user: user} do
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "ack")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "ack"
      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      assert event["origin"]["thread"] == to_string(pull.id)

      # The act must be visible in the thread, not just recorded (ENG-13).
      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.sender_id == Andon.bot_user().id and r.content =~ "acknowledged"
               end)
      end)
    end

    test "a bare issue key in a thread becomes subject_provided", %{channel: channel, user: user} do
      pull = post_message(channel, user, "pull: confusion which state does this cover")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "ENG-321")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "subject_provided"
      assert event["key"] == "ENG-321"
      assert event["provider"] == %{"relay" => "slackex", "token" => to_string(user.id)}
    end

    test "`resolved` in a thread becomes witness_close with the actor", %{
      channel: channel,
      user: user
    } do
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "resolved")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "witness_close"
      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      refute Map.has_key?(event, "puller")

      # The release is the biggest moment — it must show in the thread.
      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.sender_id == Andon.bot_user().id and r.content =~ "the hold is cleared"
               end)
      end)
    end

    test "`withdraw` in a thread becomes pull_withdrawn keyed on `puller` (not actor)", %{
      channel: channel,
      user: user
    } do
      pull = post_message(channel, user, "pull: defect something is off with the deploy")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "withdraw")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "pull_withdrawn"
      # C1: withdrawal carries `puller`, not the lifecycle `actor` field.
      assert event["puller"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      refute Map.has_key?(event, "actor")
    end

    test "`note: <text>` in a thread becomes closure_note with actor and note", %{
      channel: channel,
      user: user
    } do
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "note: flaky fixture; quarantined with a burden card")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "closure_note"
      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      assert event["note"] == "flaky fixture; quarantined with a burden card"

      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.sender_id == Andon.bot_user().id and r.content =~ "Closure note logged"
               end)
      end)
    end

    test "a bare issue key at top level is NOT an affordance", %{channel: channel, user: user} do
      post_message(channel, user, "ENG-321")
      refute_receive {:andon_event_posted, _}, 300
    end
  end

  describe "response commands render as in-thread bot replies" do
    test "a request_subject command posts the in-thread ask", %{channel: channel, user: user} do
      # The service echoes back the thread token the relay sent it (the Slack
      # message id), so the relay can resolve it to a thread to post into.
      Application.put_env(:slackex, :andon_service_stub_response, fn event ->
        {:ok,
         %{
           status: 201,
           body: %{
             "data" => %{"binding" => %{"bound" => false}},
             "commands" => [
               %{"command" => "request_subject", "thread" => event["origin"]["thread"]}
             ]
           }
         }}
      end)

      message = post_message(channel, user, "pull: delay the review has sat two days")

      assert_receive {:andon_event_posted, _}, 1_000

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.content =~ "ENG-123"
        assert reply.sender_id == Andon.bot_user().id
      end)
    end

    test "a 4xx surfaces the service error as an in-thread note", %{channel: channel, user: user} do
      Application.put_env(
        :slackex,
        :andon_service_stub_response,
        {:ok,
         %{status: 403, body: %{"errors" => %{"puller" => ["only the puller may withdraw"]}}}}
      )

      # A withdraw affordance in a thread the "wrong" person sends.
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      # first event (pull_created) uses the fun? no — it's a literal response now,
      # so pull_created also gets 403; that's fine, we only assert the note lands.
      assert_receive {:andon_event_posted, _}, 1_000

      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.content =~ "only the puller may withdraw"
               end)
      end)
    end
  end

  describe "lazy bot resolution (started without an explicit bot_id)" do
    test "resolves the bot from the DB on the first message and processes it", %{user: user} do
      # Every other test injects bot_id, so ensure_bot's DB-resolution branch
      # is otherwise never exercised. A fresh channel + a listener with no
      # bot_id makes the first message drive the lookup.
      channel = insert(:channel, creator: user, is_private: false)
      {:ok, _} = Chat.Channels.join_channel(user.id, channel.id)

      start_supervised!(
        {Andon.Listener,
         name: :listener_lazy_bot, channels: [channel.id], subscribe_on_boot: false},
        id: :listener_lazy_bot
      )

      post_message(channel, user, "pull: defect the build is red on main")

      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000
    end
  end

  describe "puller confirmation on a bound pull (ENG-13 gap 3)" do
    test "a bound pull_created posts a confirmation teaching the puller's release affordance", %{
      channel: channel,
      user: user
    } do
      Application.put_env(:slackex, :andon_service_stub_response, fn _event ->
        {:ok,
         %{
           status: 201,
           body: %{
             "data" => %{
               "binding" => %{
                 "bound" => true,
                 "subject" => %{"external_id" => "ENG-11"}
               }
             },
             "commands" => []
           }
         }}
      end)

      message =
        post_message(channel, user, "pull: burden ENG-11 deploying a service is tribal knowledge")

      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.content =~ "bound to ENG-11"
        # Teaches the puller's release affordance; not the DRI's (that's the notify).
        assert reply.content =~ "`resolved`"
        refute reply.content =~ "`ack`"
        assert reply.sender_id == Andon.bot_user().id
      end)
    end

    test "subject_provided on a previously-unbound pull posts the confirmation", %{
      channel: channel,
      user: user
    } do
      # Unbound pull gets request_subject; the confirmation waits until the
      # puller supplies the key and the pull actually binds.
      Application.put_env(:slackex, :andon_service_stub_response, fn event ->
        case event["event"] do
          "subject_provided" ->
            {:ok,
             %{
               status: 201,
               body: %{
                 "data" => %{
                   "binding" => %{"bound" => true, "subject" => %{"external_id" => "ENG-321"}}
                 },
                 "commands" => []
               }
             }}

          _ ->
            {:ok,
             %{
               status: 201,
               body: %{
                 "data" => %{"binding" => %{"bound" => false}},
                 "commands" => [
                   %{"command" => "request_subject", "thread" => event["origin"]["thread"]}
                 ]
               }
             }}
        end
      end)

      pull = post_message(channel, user, "pull: confusion which state does this cover")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "ENG-321")
      assert_receive {:andon_event_posted, %{"event" => "subject_provided"}}, 1_000

      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.content =~ "bound to ENG-321" and r.content =~ "`resolved`"
               end)
      end)
    end
  end
end
