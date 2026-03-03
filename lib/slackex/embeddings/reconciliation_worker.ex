defmodule Slackex.Embeddings.ReconciliationWorker do
  @moduledoc """
  Oban cron worker that discovers messages missing embeddings and enqueues
  `EmbeddingWorker` jobs to fill the gaps.

  Runs every 15 minutes with a 1-hour lookback window. This serves as a
  durability safety net for the `PersistenceListener` PubSub bridge -- if
  the listener was down during a `{:messages_persisted, ...}` broadcast
  (process restart, deployment, node failure), this worker catches the
  missed messages.

  Uses a LEFT JOIN between `messages` and `message_embeddings` to find
  messages that have no corresponding embedding row. Enqueues in batches
  of 50 via `EmbeddingWorker.enqueue/1`.
  """

  use Oban.Worker, queue: :embeddings, max_attempts: 1

  require Logger

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Embeddings.{EmbeddingWorker, MessageEmbedding}
  alias Slackex.Repo

  @batch_size 50
  @lookback_window_seconds 3_600

  # ---------------------------------------------------------------------------
  # Oban callback
  # ---------------------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    unembedded_message_ids = find_unembedded_message_ids()

    case unembedded_message_ids do
      [] ->
        Logger.info("ReconciliationWorker: no unembedded messages found")

      ids ->
        Logger.info("ReconciliationWorker: found #{length(ids)} unembedded messages")
        enqueue_in_batches(ids)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_unembedded_message_ids do
    lookback_cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@lookback_window_seconds, :second)
      |> DateTime.truncate(:microsecond)

    from(m in Message,
      left_join: me in MessageEmbedding,
      on: me.message_id == m.id,
      where: m.inserted_at >= ^lookback_cutoff,
      where: is_nil(m.deleted_at),
      where: is_nil(me.message_id),
      where: not is_nil(m.search_content),
      select: m.id,
      order_by: [asc: m.id]
    )
    |> Repo.all()
  end

  defp enqueue_in_batches(message_ids) do
    message_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      {:ok, jobs} = EmbeddingWorker.enqueue(batch)

      Logger.info(
        "ReconciliationWorker: enqueued #{length(jobs)} jobs for #{length(batch)} messages"
      )
    end)
  end
end
