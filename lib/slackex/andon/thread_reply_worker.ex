defmodule Slackex.Andon.ThreadReplyWorker do
  @moduledoc """
  Durably posts one bot reply into a Slack thread (slackex-xqd fix).

  slackex assigns a message id and broadcasts `message.new` immediately, then
  commits the row via an async Task. A relay reply targets that parent row, so
  the andon round-trip (broadcast → listener → bind → notify back) can beat the
  commit and find no row — pull #1 rendered `notify_dri` into a parent that
  hadn't landed yet, and the channel showed nothing. Silence reads as failure,
  and the in-thread reply *is* the product surface, so a reply must never be
  dropped to a slow write.

  The old in-listener `await_message` busy-wait (bounded 500ms, blocking the
  listener) lost that race in the field: the row's commit lagged its broadcast
  by >700ms. This worker replaces it: enqueue the reply, and retry until the
  parent row exists — durable across restarts, off the listener's path, with
  free backoff and observability. One path serves `notify_dri` and every
  affordance reply (ack / resolved / note / withdraw / correction / error note).

  Retry shape:

    * **Parent absent** → `{:snooze, 1}` (a scheduling, not a failure, so error
      telemetry stays meaningful) until `@max_wait_attempts`, then `{:cancel, _}`
      — a bounded wait that gives up rather than snoozing forever. Snooze bumps
      `max_attempts`, so the explicit attempt cap is the real bound.
    * **Send failure** → `{:error, _}` so Oban retries with backoff.
    * **Unparseable thread token** → `{:cancel, _}` (never retriable).

  Idempotency: enqueue is `unique` on the args for a 120s window (including the
  `:completed` state, since the parent is usually already persisted and the job
  completes in ms), collapsing a duplicate identical reply — an at-least-once
  re-delivery of an outbound command from the service, or an accidental
  double-enqueue. The residual window is a crash *after* `send_reply` commits but
  *before* the job acks — Oban then retries and double-posts. Accepted for the
  skeleton, matching the relay's existing 201/200 dedup caveat.
  """

  use Oban.Worker,
    queue: :andon,
    max_attempts: 15,
    # Include :completed (Oban's full default set): the parent is usually already
    # persisted, so the first job completes in ms — a duplicate that arrives just
    # after must still collapse against the completed job, not just a pending one.
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable, :completed]]

  require Logger

  alias Slackex.Chat
  alias Slackex.Messaging

  # Bounded wait for the async row commit. Snooze increments `attempt`, so this
  # caps total snoozes (~@max_wait_attempts * @snooze_seconds of waiting) — well
  # past the >700ms lag observed in the field, and durable across a restart.
  @snooze_seconds 1
  @max_wait_attempts 15

  @doc "Enqueues a durable reply of `text` into the thread rooted at `thread`."
  @spec enqueue(integer(), integer(), term(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(channel_id, bot_id, thread, text) do
    %{
      "channel_id" => channel_id,
      "bot_id" => bot_id,
      "thread" => to_string(thread),
      "text" => text
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    %{
      "channel_id" => channel_id,
      "bot_id" => bot_id,
      "thread" => thread,
      "text" => text
    } = args

    with {parent_id, ""} <- Integer.parse(to_string(thread)),
         {:ok, _parent} <- Chat.get_message(parent_id) do
      send_reply(channel_id, bot_id, parent_id, text)
    else
      :error ->
        {:cancel, "unparseable thread token #{inspect(thread)}"}

      {:error, :not_found} ->
        wait_or_give_up(attempt, thread)

      other ->
        {:cancel, "unexpected parent lookup for thread #{inspect(thread)}: #{inspect(other)}"}
    end
  end

  defp wait_or_give_up(attempt, _thread) when attempt < @max_wait_attempts,
    do: {:snooze, @snooze_seconds}

  defp wait_or_give_up(_attempt, thread) do
    Logger.warning(
      "andon relay: gave up on thread reply — parent #{thread} never persisted " <>
        "after #{@max_wait_attempts} attempts"
    )

    {:cancel, "parent message #{thread} never persisted"}
  end

  defp send_reply(channel_id, bot_id, parent_id, text) do
    case Messaging.send_reply(channel_id, :channel, bot_id, parent_id, text) do
      {:ok, _reply} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:exception, error.__struct__}}
  end
end
