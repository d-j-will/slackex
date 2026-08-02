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
  alias Slackex.Andon.Grammar
  alias Slackex.Andon.NotePrompt
  alias Slackex.Chat
  alias Slackex.Messaging

  # Unique to the class correction (ENG-72). The class *question* also says
  # "reply with one word", so asserting on that would match the question and
  # make every negative case pass for the wrong reason.
  @correction_marker ~r/on its own/i

  setup do
    user = insert(:user, username: "puller-anna")
    channel = insert(:channel, creator: user, is_private: false)
    bot = Andon.bot_user()

    {:ok, _} = Chat.Channels.join_channel(user.id, channel.id)
    {:ok, _} = Chat.Channels.join_channel(bot.id, channel.id)

    # A real relay channel has its `andon_channels` row — it is what the mirror
    # lands on, and without it `apply_command/1` drops the update silently.
    #
    # Written with `enable_channel/1`'s own changeset rather than through
    # `enable_channel/1` itself, and the difference is one line: the announce
    # on the control topic. `Slackex.Andon.Listener` sits in the application
    # supervision tree and subscribes to that topic whatever its boot options
    # say, so announcing here makes the *global* listener subscribe to this
    # test's channel alongside the one the test supervises — and every message
    # is then processed twice. The row is the fixture; the broadcast is not.
    {:ok, _} =
      %Andon.Channel{}
      |> Andon.Channel.enable_changeset(%{channel_id: channel.id})
      |> Slackex.Repo.insert()

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
    test "a class word with no sentence posts an in-thread correction and sends NO event", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: defect")

      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.content =~ "pull:"
        assert reply.sender_id == Andon.bot_user().id
      end)
    end
  end

  describe "the bare cord (ENG-45)" do
    test "a pull with no class word is a valid pull, classless, sentence verbatim", %{
      channel: channel,
      user: user
    } do
      post_message(channel, user, "pull: I'm a bit stuck here, someone help")

      assert_receive {:andon_event_posted, event}, 1_000

      assert event["event"] == "pull_created"
      refute Map.has_key?(event, "class")
      assert event["sentence"] == "I'm a bit stuck here, someone help"
    end

    test "a typo'd class word is sentence, not a rejection", %{channel: channel, user: user} do
      post_message(channel, user, "pull: defct the build is broken")

      assert_receive {:andon_event_posted, event}, 1_000
      refute Map.has_key?(event, "class")
      assert event["sentence"] == "defct the build is broken"
    end

    test "the bot asks the class question once, in human words, in the thread", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")

      assert_receive {:andon_event_posted, _event}, 1_000

      eventually(fn ->
        replies = Chat.list_thread(message.id)
        question = Enum.find(replies, &(&1.content =~ "defect"))

        assert question, "expected an in-thread class question naming the classes"
        assert question.sender_id == Andon.bot_user().id

        # All four classes, each in human words — an answer key, not a syntax
        # demand. And exactly one question: asked once, never repeated.
        for class <- Grammar.classes(), do: assert(question.content =~ class)
        assert Enum.count(replies, &(&1.content =~ "defect")) == 1
      end)
    end

    test "a classed pull gets no class question", %{channel: channel, user: user} do
      message = post_message(channel, user, "pull: defect the build is red on main")

      assert_receive {:andon_event_posted, _event}, 1_000

      eventually(fn ->
        replies = Chat.list_thread(message.id)
        refute Enum.any?(replies, &(&1.content =~ "confusion"))
      end)
    end

    test "a one-word class reply in the thread becomes class_provided", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      reply = post_reply(channel, user, message.id, "defect")

      assert_receive {:andon_event_posted, event}, 1_000

      assert event["event"] == "class_provided"
      assert event["event_id"] == "slackex-#{reply.id}"
      assert event["class"] == "defect"
      assert event["provider"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      assert event["origin"]["thread"] == to_string(message.id)

      # The act is visible in the thread, like every lifecycle transition.
      eventually(fn ->
        replies = Chat.list_thread(message.id)

        assert Enum.any?(
                 replies,
                 &(&1.content =~ "defect" and &1.sender_id == Andon.bot_user().id and
                     &1.id != reply.id)
               )
      end)
    end

    test "a phone-capitalised class reply still answers (ADR-0014's rule holds here too)", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, message.id, "Confusion.")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "class_provided"
      assert event["class"] == "confusion"
    end

    test "a bare class word at channel top level is ordinary traffic, not an answer", %{
      channel: channel,
      user: user
    } do
      post_message(channel, user, "defect")

      refute_receive {:andon_event_posted, _}, 300
    end
  end

  describe "a class answer with one extra word (ENG-72)" do
    # ADR-0014 decision 3 — "an attempt is never ignored" — was written for
    # `pull:` and never extended to the questions the bot asks afterwards. The
    # whole-message rule stays (ADR-0016 puts no arming on the class question,
    # so anyone may answer at any time and "starts with a class word" would
    # class an ordinary sentence). What changes is that a near-miss earns a
    # sentence instead of silence.
    #
    # The guard is the channel mirror: a correction is only owed where a pull
    # in this thread is actually still waiting for its class.

    test "the field case: `defect dogfooding` earns a correction and logs nothing", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      mirror(channel, unbound_pull(message.id, nil))

      post_reply(channel, user, message.id, "defect dogfooding")

      # Records nothing: the class is not taken from a message that was not
      # bare, so no event crosses the seam.
      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        correction = bot_reply_matching(message.id, @correction_marker)

        assert correction,
               "expected an in-thread correction, got: #{inspect(bot_replies(message.id))}"

        # The answer key is repeated, so the correction is usable on its own.
        for class <- Grammar.classes(), do: assert(correction.content =~ class)
      end)
    end

    test "a bound pull still waiting for its class earns it too (active_holds)", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: ENG-9 I'm a bit stuck here")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      mirror(channel, active_hold(message.id, nil))

      post_reply(channel, user, message.id, "burden all this ceremony")

      refute_receive {:andon_event_posted, _}, 300
      eventually(fn -> assert bot_reply_matching(message.id, @correction_marker) end)
    end

    # The discriminating case: same thread, same shape of message, but the
    # pull already knows its class — so there is no question outstanding and
    # "defect rates are up this week" is ordinary thread talk.
    test "a pull that already has its class gets no correction", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: defect the build is red on main")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      mirror(channel, unbound_pull(message.id, "defect"))

      post_reply(channel, user, message.id, "defect rates are up this week")

      refute_correction_after(channel, user, message.id, @correction_marker)
    end

    test "a classless pull in a different thread earns no correction here", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      # Classless, but it is some other thread's pull.
      mirror(channel, unbound_pull(message.id + 9_999, nil))

      post_reply(channel, user, message.id, "defect rates are up this week")

      refute_correction_after(channel, user, message.id, @correction_marker)
    end

    test "a message that merely mentions a class earns no correction", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      mirror(channel, unbound_pull(message.id, nil))

      # Only a message that OPENS with a class word is a plausible answer —
      # the same message-start rule the keyword itself keeps (ADR-0014 §2).
      post_reply(channel, user, message.id, "this looks like a defect to me")

      refute_correction_after(channel, user, message.id, @correction_marker)
    end

    # A thread can hold a released pull awaiting its closure note AND an open
    # classless pull (ENG-54). The prompt is addressed to one person and is
    # armed; the class question is neither. The addressed question wins, or
    # ENG-74's one chance gets spent by a correction nobody asked for.
    test "a pending closure-note prompt wins over the class correction", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull: I'm a bit stuck here, someone help")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      mirror(channel, unbound_pull(message.id, nil))

      :ok =
        NotePrompt.arm(
          channel.id,
          message.id,
          "6a0c6d1e-0000-4000-8000-00000000beef",
          to_string(user.id)
        )

      post_reply(channel, user, message.id, "defect dogfooding")

      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        assert bot_reply_matching(message.id, ~r/cause:/i),
               "expected the cause prompt, got: #{inspect(bot_replies(message.id))}"
      end)

      # No barrier needed here: the cause prompt above IS the proof this
      # message was handled to completion, and the correction would have been
      # written in the same pass.
      refute bot_reply_matching(message.id, @correction_marker)
    end
  end

  # The mirror is how the relay knows a pull is still waiting for its class:
  # the service pushes it, and `apply_command/1` is the production path that
  # lands it on the channel row.
  defp mirror(channel, %{active_holds: holds, unbound_pulls: unbound}) do
    :ok =
      Andon.apply_command(%{
        "command" => "update_mirror",
        "channel" => to_string(channel.id),
        "watermark" => System.unique_integer([:positive, :monotonic]),
        "mirror" => %{
          "active_holds" => holds,
          "unbound_pulls" => unbound,
          "oldest_open" => nil
        }
      })

    # `apply_command/1` answers `:ok` when it drops a command it cannot place,
    # so the return value proves nothing. Read the mirror back, or a test that
    # never set one up passes for the wrong reason.
    assert Andon.mirror_for_channel(channel.id) != %{},
           "the mirror did not land — the channel has no andon_channels row"
  end

  defp unbound_pull(thread_id, class) do
    %{
      active_holds: [],
      unbound_pulls: [
        %{
          "pull_id" => "p-#{thread_id}",
          "class" => class,
          "thread" => to_string(thread_id),
          "since" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ]
    }
  end

  defp active_hold(thread_id, class) do
    %{
      unbound_pulls: [],
      active_holds: [
        %{
          "pull_id" => "p-#{thread_id}",
          "class" => class,
          "thread" => to_string(thread_id),
          "subject" => %{"adapter" => "linear", "external_id" => "ENG-9"},
          "held_since" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "escalated" => false,
          "holder" => %{"relay" => "slackex", "token" => "1"},
          "holder_source" => "dri",
          "acked_at" => nil,
          "ack_due_at" => nil,
          "epoch" => 0,
          "actions" => []
        }
      ]
    }
  end

  defp bot_replies(thread_id) do
    thread_id
    |> Chat.list_thread()
    |> Enum.filter(&(&1.sender_id == Andon.bot_user().id))
  end

  defp bot_reply_matching(thread_id, regex) do
    thread_id |> bot_replies() |> Enum.find(&Regex.match?(regex, &1.content))
  end

  # A negative assertion needs to know the message was FINISHED with, not just
  # that nothing has shown up yet — and a fixed sleep only ever proves the
  # latter. It would pass on a slow runner while the correction was in flight.
  #
  # The barrier: the listener is one GenServer taking a channel's messages in
  # order, and Oban runs inline in test (`testing: :inline`), so a message is
  # completely handled — bot reply written — before the next is picked up.
  # Observing a LATER message's event is therefore proof the earlier one is
  # done. A bare `defect` is the cheapest such message: it always produces
  # `class_provided`, and the mirror is a fixture so answering does not disturb
  # it.
  defp refute_correction_after(channel, user, thread_id, regex) do
    post_reply(channel, user, thread_id, "defect")
    assert_receive {:andon_event_posted, %{"event" => "class_provided"}}, 1_000

    # The sentinel's own event has been consumed; anything still queued was
    # produced by the message under test, which was supposed to record nothing.
    refute_received {:andon_event_posted, _}

    refute bot_reply_matching(thread_id, regex),
           "expected no correction, got: #{inspect(bot_replies(thread_id))}"
  end

  describe "a pull typed on a phone" do
    test "a capitalised keyword still posts the pull (ADR-0014)", %{channel: channel, user: user} do
      post_message(channel, user, "Pull: defect the build is red on main")

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "pull_created"
      assert event["class"] == "defect"
      assert event["sentence"] == "the build is red on main"
    end

    test "an attempt that does not complete is answered, never ignored", %{
      channel: channel,
      user: user
    } do
      message = post_message(channel, user, "pull:")

      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.sender_id == Andon.bot_user().id
        assert reply.content =~ "pull:"
      end)
    end
  end

  describe "asking what you can type" do
    test "answers with the vocabulary and sends NO event", %{channel: channel, user: user} do
      message = post_message(channel, user, "andon help")

      refute_receive {:andon_event_posted, _}, 300

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)
        assert reply.sender_id == Andon.bot_user().id

        # The whole vocabulary, because this was asked for rather than pushed:
        # how to pull, what the puller says to close, what a responder says.
        assert reply.content =~ "pull:"
        assert reply.content =~ "resolved"
        assert reply.content =~ "heard"
        assert reply.content =~ "note:"
      end)
    end

    test "names every class the grammar accepts", %{channel: channel, user: user} do
      message = post_message(channel, user, "andon help")

      eventually(fn ->
        assert [reply] = Chat.list_thread(message.id)

        for class <- Grammar.classes() do
          assert reply.content =~ class
        end
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

  describe "in-thread phrases (replies only)" do
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

    test "`note:` + `cause:` in a thread becomes closure_note with both halves", %{
      channel: channel,
      user: user
    } do
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(
        channel,
        user,
        pull.id,
        "note: flaky fixture; quarantined with a burden card\ncause: shared test DB not reset"
      )

      assert_receive {:andon_event_posted, event}, 1_000
      assert event["event"] == "closure_note"
      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(user.id)}
      assert event["note"] == "flaky fixture; quarantined with a burden card"
      assert event["cause_guess"] == "shared test DB not reset"

      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.sender_id == Andon.bot_user().id and r.content =~ "Closure note logged"
               end)
      end)
    end

    test "a note with no cause is not logged — the bot asks for the cause instead", %{
      channel: channel,
      user: user
    } do
      pull = post_message(channel, user, "pull: defect ENG-9 is red")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, user, pull.id, "note: flaky fixture; quarantined")

      # Nothing reaches the service: half a closure note is worse than a
      # prompt, because the cause is gone once the person moves on.
      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300

      eventually(fn ->
        assert Enum.any?(Chat.list_thread(pull.id), fn r ->
                 r.sender_id == Andon.bot_user().id and
                   r.content =~ "I need the cause alongside it"
               end)
      end)
    end

    test "a bare issue key at top level is NOT a phrase", %{channel: channel, user: user} do
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

      # A withdraw phrase in a thread the "wrong" person sends.
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
    test "a bound pull_created posts a confirmation teaching the puller's release phrase", %{
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
        # Teaches the puller's release phrase; not the DRI's (that's the notify).
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
