defmodule Slackex.Embeddings.PersistenceListener do
  @moduledoc """
  Supervised GenServer that subscribes to the `"pipeline:events"` PubSub topic
  and enqueues `EmbeddingWorker` jobs when messages are persisted.

  BatchWriter broadcasts `{:messages_persisted, message_ids}` after successful
  batch inserts. This listener picks up those events and feeds message IDs into
  the embedding pipeline, bridging the persistence and embeddings concerns
  without introducing a boundary dependency (PubSub is OTP infrastructure).

  If the listener is down during a broadcast (restart, deployment), the
  `ReconciliationWorker` cron job serves as a durability safety net.
  """

  use GenServer

  require Logger

  alias Slackex.Embeddings.EmbeddingWorker

  @pubsub Slackex.PubSub
  @topic "pipeline:events"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    _ = Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:messages_persisted, message_ids}, state) when is_list(message_ids) do
    Logger.info("PersistenceListener: received #{length(message_ids)} message IDs for embedding")

    {:ok, jobs} = EmbeddingWorker.enqueue(message_ids)
    Logger.info("PersistenceListener: enqueued #{length(jobs)} EmbeddingWorker jobs")

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end
end
