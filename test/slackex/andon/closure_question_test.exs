defmodule Slackex.Andon.ClosureQuestionTest do
  @moduledoc """
  End-to-end for the question asked at release (andon ENG-60, ADR-0017):
  the release line carries one question addressed to whoever held the pull,
  and the holder answers it in plain words — no grammar to remember.

  Drives the real `message.new` flow through a dedicated listener, with the
  service seam stubbed, so what is asserted is what a person in the channel
  would see and what the service would receive.

  async: false — ChannelServer + the listener need shared sandbox access.
  """
  use Slackex.DataCase, async: false

  alias Slackex.Andon
  alias Slackex.Andon.NotePrompt
  alias Slackex.Chat
  alias Slackex.Messaging

  @pull_id "6a0c6d1e-0000-4000-8000-00000000beef"

  setup do
    puller = insert(:user, username: "puller-anna")
    holder = insert(:user, username: "holder-ben")
    channel = insert(:channel, creator: puller, is_private: false)
    bot = Andon.bot_user()

    {:ok, _} = Chat.Channels.join_channel(puller.id, channel.id)
    {:ok, _} = Chat.Channels.join_channel(holder.id, channel.id)
    {:ok, _} = Chat.Channels.join_channel(bot.id, channel.id)

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

    %{puller: puller, holder: holder, channel: channel, bot: bot}
  end

  # The service asks the question on a fresh release and never on a replay.
  defp stub_asking_at_release(holder) do
    command = %{
      "command" => "request_closure_note",
      "holder" => %{"relay" => "slackex", "token" => to_string(holder.id)},
      "pull_id" => @pull_id,
      "channel" => "ignored-here",
      "thread" => "ignored-here"
    }

    Application.put_env(:slackex, :andon_service_stub_response, fn event ->
      commands = if event["event"] == "witness_close", do: [command], else: []
      {:ok, %{status: 201, body: %{"data" => %{}, "commands" => commands}}}
    end)
  end

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

  defp prompts_asking_for_cause(pull) do
    bot_id = Andon.bot_user().id

    pull.id
    |> Chat.list_thread()
    |> Enum.count(&(&1.sender_id == bot_id and &1.content =~ "I need the cause"))
  end

  # A pull, released by its puller, with the question asked.
  defp released_pull(channel, puller, holder) do
    stub_asking_at_release(holder)
    pull = post_message(channel, puller, "pull: defect ENG-123 is red on main")
    assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

    post_reply(channel, puller, pull.id, "resolved")
    assert_receive {:andon_event_posted, %{"event" => "witness_close"}}, 1_000

    # The arming is the relay's half; wait for it rather than for the post.
    eventually(fn -> assert %NotePrompt{} = NotePrompt.latest(channel.id, pull.id) end)

    pull
  end

  describe "the question" do
    test "the release line and the question are one message, addressed to the holder", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      eventually(fn ->
        replies = Chat.list_thread(pull.id)
        bot_id = Andon.bot_user().id

        # One message, not two: two ThreadReplyWorker jobs have no ordering
        # between them, and "Released" after the question reads as nonsense.
        assert [release_line] =
                 Enum.filter(replies, &(&1.sender_id == bot_id and &1.content =~ "Released"))

        assert release_line.content =~ "the hold is cleared"
        assert release_line.content =~ "@holder-ben"
        assert release_line.content =~ "cause:"
        assert release_line.content =~ "no note"
      end)
    end

    test "a release the service asks nothing about just says released", %{
      channel: channel,
      puller: puller
    } do
      pull = post_message(channel, puller, "pull: defect ENG-123 is red on main")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, puller, pull.id, "resolved")
      assert_receive {:andon_event_posted, %{"event" => "witness_close"}}, 1_000

      eventually(fn ->
        bot_id = Andon.bot_user().id

        assert [line] =
                 Chat.list_thread(pull.id)
                 |> Enum.filter(&(&1.sender_id == bot_id and &1.content =~ "Released"))

        refute line.content =~ "cause:"
      end)

      assert nil == NotePrompt.latest(channel.id, pull.id)
    end
  end

  describe "answering in plain words" do
    test "the holder's prose with a cause becomes a closure_note naming its pull", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(
        channel,
        holder,
        pull.id,
        "the migration had not run on the box\ncause: seed script skips it outside CI"
      )

      assert_receive {:andon_event_posted, %{"event" => "closure_note"} = event}, 1_000

      # No `note:` prefix anywhere — the bot asked, so the message is the answer.
      assert event["note"] =~ "the migration had not run on the box"
      assert event["cause_guess"] == "seed script skips it outside CI"
      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(holder.id)}

      # The pull the question named, so a thread with two closed pulls still
      # addresses the right one (the narrow slice of ENG-54).
      assert event["pull_id"] == @pull_id
    end

    test "prose with no cause asks for the cause and logs no half a note", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      reply = post_reply(channel, holder, pull.id, "it was the migration again")

      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300

      eventually(fn ->
        bot_id = Andon.bot_user().id
        replies = Chat.list_thread(pull.id)

        assert Enum.any?(replies, fn m ->
                 m.sender_id == bot_id and m.id > reply.id and m.content =~ "I need the cause"
               end)
      end)
    end

    # The sequence that actually happened in production on 2026-07-30 (ENG-74).
    # Two of the holder's four messages produced nothing at all, because the
    # first attempt spent the arming and the corrective prompt then taught a
    # shape to someone who no longer had an arming to use it with.
    test "a half-answer does not spend the question — the next attempt still lands", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "cause: dogfooding")
      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300

      # The attempt produced no record, so it cannot have cost the one chance.
      assert %NotePrompt{spent_at: nil} = NotePrompt.latest(channel.id, pull.id)

      # And the second attempt — plain prose, the shape the question asked
      # for — lands, without the exact string having to be dictated.
      post_reply(channel, holder, pull.id, "dogfooding test / cause: dogfooding")

      assert_receive {:andon_event_posted, %{"event" => "closure_note"} = event}, 1_000
      assert event["note"] == "dogfooding test"
      assert event["cause_guess"] == "dogfooding"
      assert event["pull_id"] == @pull_id

      # Now it is spent: a note landed.
      eventually(fn ->
        assert %NotePrompt{spent_at: %DateTime{}} = NotePrompt.latest(channel.id, pull.id)
      end)
    end

    test "the correction is offered once — an open arming is not a standing nag", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "it was the migration again")
      eventually(fn -> assert prompts_asking_for_cause(pull) == 1 end)

      post_reply(channel, holder, pull.id, "anyway, off to lunch")
      post_reply(channel, holder, pull.id, "back now")

      # Still listening, still silent: the question was asked once and the
      # correction once. Nothing re-asks.
      Process.sleep(200)
      assert prompts_asking_for_cause(pull) == 1
      assert %NotePrompt{spent_at: nil} = NotePrompt.latest(channel.id, pull.id)
    end

    test "declining spends the arming, so later chatter is chatter again", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "no note")
      assert_receive {:andon_event_posted, %{"event" => "closure_note_declined"}}, 1_000

      eventually(fn ->
        assert %NotePrompt{spent_at: %DateTime{}} = NotePrompt.latest(channel.id, pull.id)
      end)

      post_reply(channel, holder, pull.id, "though it was the migration again")

      Process.sleep(200)
      assert prompts_asking_for_cause(pull) == 0
    end

    test "a typed note spends the arming too", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "note: flaky fixture / cause: shared test DB")
      assert_receive {:andon_event_posted, %{"event" => "closure_note"}}, 1_000

      eventually(fn ->
        assert %NotePrompt{spent_at: %DateTime{}} = NotePrompt.latest(channel.id, pull.id)
      end)

      post_reply(channel, holder, pull.id, "anyway, off to lunch")

      Process.sleep(200)
      assert prompts_asking_for_cause(pull) == 0
    end

    test "the cause prompt tells the truth: answering it lands a note", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      # The expected first reply to the question: prose, no cause marker.
      post_reply(channel, holder, pull.id, "it was the migration again")
      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300

      # Whatever the bot asks for next must be something that actually lands.
      # The arming survives a failed attempt (ENG-74), but the prose does not:
      # nothing is held between messages, so a bare `cause:` line would answer
      # with no note to attach it to. The copy must not promise otherwise.
      eventually(fn ->
        bot_id = Andon.bot_user().id

        assert prompt =
                 Chat.list_thread(pull.id)
                 |> Enum.find(
                   &(&1.sender_id == bot_id and &1.content =~ "cause:" and
                       not (&1.content =~ "Released"))
                 )
                 |> then(& &1.content)

        # It must teach a shape that actually lands. A bare `cause:` line
        # parses as ordinary chatter against a spent arming and vanishes.
        assert prompt =~ "note:"
      end)

      post_reply(channel, holder, pull.id, "note: the migration again / cause: seed skips it")

      assert_receive {:andon_event_posted, %{"event" => "closure_note"} = event}, 1_000
      assert event["cause_guess"] == "seed skips it"
      assert event["pull_id"] == @pull_id
    end

    test "a reply from someone who was not asked stays ordinary chatter", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      # The puller saying thanks is not a closure note.
      post_reply(channel, puller, pull.id, "nice one, thanks for picking that up")

      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300
      assert %NotePrompt{spent_at: nil} = NotePrompt.latest(channel.id, pull.id)
    end

    test "armed once: once a note lands, the holder's next message is chatter again", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "the cache was stale\ncause: deploy does not bust it")
      assert_receive {:andon_event_posted, %{"event" => "closure_note"}}, 1_000

      post_reply(channel, holder, pull.id, "anyway, off to lunch")

      refute_receive {:andon_event_posted, %{"event" => "closure_note"}}, 300
    end
  end

  describe "declining" do
    test "`no note` is an answer: a closure_note_declined naming its pull", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "no note")

      assert_receive {:andon_event_posted, %{"event" => "closure_note_declined"} = event}, 1_000

      assert event["actor"] == %{"relay" => "slackex", "token" => to_string(holder.id)}
      assert event["pull_id"] == @pull_id
      refute Map.has_key?(event, "note")
      refute Map.has_key?(event, "cause_guess")
    end

    test "the bot answers a decline without a second ask", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)
      post_reply(channel, holder, pull.id, "no note")

      eventually(fn ->
        bot_id = Andon.bot_user().id

        # Not "the message after theirs": bot replies are enqueued jobs, so
        # the release line can still be landing when the answer arrives.
        assert [ack] =
                 Chat.list_thread(pull.id)
                 |> Enum.filter(&(&1.sender_id == bot_id and &1.content =~ "Logged as"))

        assert ack.content =~ "no note"
        assert ack.content =~ "that's an answer"
        # Nothing that reads as disappointment, and no second ask.
        refute ack.content =~ "cause:"
      end)
    end
  end

  describe "the typed grammar still works, and now names its pull too" do
    test "a `note:` typed in an asked thread carries the pull id", %{
      channel: channel,
      puller: puller,
      holder: holder
    } do
      pull = released_pull(channel, puller, holder)

      post_reply(channel, holder, pull.id, "note: flaky fixture / cause: shared test DB")

      assert_receive {:andon_event_posted, %{"event" => "closure_note"} = event}, 1_000

      assert event["note"] =~ "flaky fixture"
      assert event["cause_guess"] == "shared test DB"
      assert event["pull_id"] == @pull_id
    end

    test "a `note:` in a thread that was never asked carries no id — the service falls back", %{
      channel: channel,
      puller: puller
    } do
      pull = post_message(channel, puller, "pull: defect ENG-123 is red on main")
      assert_receive {:andon_event_posted, %{"event" => "pull_created"}}, 1_000

      post_reply(channel, puller, pull.id, "note: fixed / cause: a guess")

      assert_receive {:andon_event_posted, %{"event" => "closure_note"} = event}, 1_000
      refute Map.has_key?(event, "pull_id")
    end
  end
end
