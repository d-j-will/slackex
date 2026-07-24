defmodule Slackex.Andon.ThreadReplyWorkerTest do
  @moduledoc """
  Unit tests for the durable thread-reply worker (slackex-xqd fix).

  These cover the retry-until-persisted edge the listener/controller boundary
  tests can't reach: under `testing: :inline` Oban runs `perform/1` once at
  insert time with the parent row already present, so the
  not-yet-persisted → snooze → give-up cycle — the whole point of the fix — is
  only exercised by driving `perform/1` directly with a controlled attempt.
  """
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  import Ecto.Query

  alias Slackex.Andon
  alias Slackex.Andon.ThreadReplyWorker
  alias Slackex.Chat

  setup do
    user = insert(:user, username: "puller-anna")
    channel = insert(:channel, creator: user, is_private: false)
    bot = Andon.bot_user()
    {:ok, _} = Chat.Channels.join_channel(bot.id, channel.id)
    %{user: user, channel: channel, bot: bot}
  end

  defp args(channel_id, bot_id, thread, text) do
    %{
      "channel_id" => channel_id,
      "bot_id" => bot_id,
      "thread" => to_string(thread),
      "text" => text
    }
  end

  describe "perform/1 when the parent message exists" do
    test "posts the reply into the thread as the bot and completes", %{
      channel: channel,
      user: user,
      bot: bot
    } do
      parent = insert(:message, channel: channel, sender: user)

      assert :ok =
               perform_job(
                 ThreadReplyWorker,
                 args(
                   channel.id,
                   bot.id,
                   parent.id,
                   "you're the DRI for this pull. It's on the clock."
                 )
               )

      assert [reply] = Chat.list_thread(parent.id)
      assert reply.sender_id == bot.id
      assert reply.content =~ "on the clock"
    end
  end

  describe "perform/1 when the parent has not persisted yet (the async-persistence race)" do
    # A thread id no message row exists for — stands in for the window between
    # ChannelServer's message.new broadcast and the async row commit.
    @absent_thread "9999999999"

    test "snoozes rather than dropping the reply while within the bounded wait", %{
      channel: channel,
      bot: bot
    } do
      assert {:snooze, _seconds} =
               perform_job(
                 ThreadReplyWorker,
                 args(channel.id, bot.id, @absent_thread, "on the clock"),
                 attempt: 1
               )

      # Nothing posted: the reply is durably deferred, never lost.
      assert Chat.list_thread(String.to_integer(@absent_thread)) == []
    end

    test "gives up (cancels) once the bounded wait is exhausted", %{channel: channel, bot: bot} do
      assert {:cancel, reason} =
               perform_job(
                 ThreadReplyWorker,
                 args(channel.id, bot.id, @absent_thread, "on the clock"),
                 attempt: 15
               )

      assert reason =~ "never persisted"
    end
  end

  describe "enqueue/4 idempotency (guards the notify_dri 201+push double and snooze re-enqueue)" do
    test "collapses a duplicate identical reply within the unique window" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, job1} = ThreadReplyWorker.enqueue(1, 2, "T-100", "on the clock")
        refute job1.conflict?

        assert {:ok, job2} = ThreadReplyWorker.enqueue(1, 2, "T-100", "on the clock")
        assert job2.conflict?
        assert job2.id == job1.id
      end)
    end

    test "collapses a duplicate even after the first reply has completed (healthy fast-parent case)" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, job1} = ThreadReplyWorker.enqueue(1, 2, "T-100", "on the clock")

        # The fast-parent path: the parent row was already committed, so the
        # first job ran and completed in single-digit ms. A duplicate that
        # arrives just after (an at-least-once re-delivery) must still collapse.
        {1, _} =
          Repo.update_all(
            from(j in Oban.Job, where: j.id == ^job1.id),
            set: [state: "completed", completed_at: DateTime.utc_now()]
          )

        assert {:ok, job2} = ThreadReplyWorker.enqueue(1, 2, "T-100", "on the clock")
        assert job2.conflict?
        assert job2.id == job1.id
      end)
    end

    test "a different reply text to the same thread is not collapsed" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, job1} = ThreadReplyWorker.enqueue(1, 2, "T-100", "ack recorded")
        assert {:ok, job2} = ThreadReplyWorker.enqueue(1, 2, "T-100", "resolved — hold released")
        refute job2.conflict?
        refute job2.id == job1.id
      end)
    end
  end
end
