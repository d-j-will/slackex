defmodule Slackex.Embeddings.EmbeddingWorker do
  @moduledoc """
  Oban worker that generates and persists vector embeddings for messages.

  Handles two job types via args pattern matching in `perform/1`:

  - **Batch embedding** (`%{"message_ids" => [...]}`) -- fetches messages by ID,
    filters out deleted and already-embedded (matching content_hash), generates
    embeddings via `EmbeddingClient`, and upserts into `message_embeddings`.

  - **Channel backfill** (`%{"channel_id" => id, "backfill" => true}`) -- streams
    all unembedded messages for a channel, processing in batches of 50 with pauses.

  Public helpers:

  - `enqueue/1` -- chunks message IDs into batches of 50, inserts one job per batch.
  - `enqueue_backfill/1` -- creates a unique-per-channel backfill job (1hr window).
  """

  use Oban.Worker, queue: :embeddings, max_attempts: 3, priority: 3

  require Logger

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}
  alias Slackex.Repo

  @batch_size 50
  @backfill_pause_ms 1_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Enqueues embedding jobs for the given message IDs.

  Chunks the IDs into batches of #{@batch_size} and inserts one Oban job per batch
  at priority 3. Returns `{:ok, [%Oban.Job{}, ...]}`.
  """
  @spec enqueue([integer()]) :: {:ok, [Oban.Job.t()]}
  def enqueue(message_ids) when is_list(message_ids) do
    jobs =
      message_ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(fn batch ->
        %{message_ids: batch}
        |> new(priority: 3)
        |> Oban.insert!()
      end)

    {:ok, jobs}
  end

  @doc """
  Enqueues a backfill job for a channel or DM conversation.

  Uses Oban uniqueness to prevent duplicate backfills within a 1-hour window.
  """
  @spec enqueue_backfill(keyword()) :: {:ok, Oban.Job.t()}
  def enqueue_backfill(channel_id: channel_id) do
    job =
      %{channel_id: channel_id, backfill: true}
      |> new(
        priority: 3,
        unique: [period: 3600, keys: [:channel_id]]
      )
      |> Oban.insert!()

    {:ok, job}
  end

  def enqueue_backfill(dm_conversation_id: dm_id) do
    job =
      %{dm_conversation_id: dm_id, backfill: true}
      |> new(
        priority: 3,
        unique: [period: 3600, keys: [:dm_conversation_id]]
      )
      |> Oban.insert!()

    {:ok, job}
  end

  # ---------------------------------------------------------------------------
  # Oban callbacks
  # ---------------------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_ids" => message_ids}}) do
    message_ids
    |> fetch_embeddable_messages()
    |> generate_and_persist_embeddings()

    :ok
  end

  def perform(%Oban.Job{args: %{"channel_id" => channel_id, "backfill" => true}}) do
    backfill_channel(channel_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"dm_conversation_id" => dm_id, "backfill" => true}}) do
    backfill_dm(dm_id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Batch embedding pipeline
  # ---------------------------------------------------------------------------

  defp fetch_embeddable_messages(message_ids) do
    from(m in Message,
      left_join: me in MessageEmbedding,
      on: me.message_id == m.id,
      where: m.id in ^message_ids,
      where: is_nil(m.deleted_at),
      where:
        is_nil(me.message_id) or
          me.content_hash != fragment("encode(sha256(?::bytea), 'hex')", m.search_content),
      select: m
    )
    |> Repo.all()
    |> Enum.filter(&(&1.search_content != nil))
  end

  defp generate_and_persist_embeddings([]), do: :ok

  defp generate_and_persist_embeddings(messages) do
    texts = Enum.map(messages, & &1.search_content)

    case EmbeddingClient.generate_batch(texts) do
      {:ok, vectors} ->
        messages
        |> Enum.zip(vectors)
        |> Enum.each(fn {message, vector} ->
          upsert_embedding(message, vector)
        end)

      {:error, reason} ->
        Logger.error("EmbeddingWorker: batch generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_embedding(message, vector) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = compute_content_hash(message.search_content)

    attrs = %{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: vector,
      content_hash: hash,
      inserted_at: now
    }

    %MessageEmbedding{}
    |> MessageEmbedding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:embedding, :content_hash, :inserted_at]},
      conflict_target: :message_id
    )
  end

  # ---------------------------------------------------------------------------
  # Backfill pipeline
  # ---------------------------------------------------------------------------

  defp backfill_channel(channel_id) do
    unembedded_message_ids_query(channel_id: channel_id)
    |> process_backfill_stream()
  end

  defp backfill_dm(dm_id) do
    unembedded_message_ids_query(dm_conversation_id: dm_id)
    |> process_backfill_stream()
  end

  defp unembedded_message_ids_query(channel_id: channel_id) do
    from(m in Message,
      left_join: me in MessageEmbedding,
      on: me.message_id == m.id,
      where: m.channel_id == ^channel_id,
      where: is_nil(m.deleted_at),
      where: is_nil(me.message_id),
      select: m.id,
      order_by: [asc: m.id]
    )
  end

  defp unembedded_message_ids_query(dm_conversation_id: dm_id) do
    from(m in Message,
      left_join: me in MessageEmbedding,
      on: me.message_id == m.id,
      where: m.dm_conversation_id == ^dm_id,
      where: is_nil(m.deleted_at),
      where: is_nil(me.message_id),
      select: m.id,
      order_by: [asc: m.id]
    )
  end

  defp process_backfill_stream(query) do
    query
    |> Repo.all()
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      batch
      |> fetch_embeddable_messages()
      |> generate_and_persist_embeddings()

      Process.sleep(@backfill_pause_ms)
    end)
  end

  # ---------------------------------------------------------------------------
  # Pure helpers
  # ---------------------------------------------------------------------------

  defp compute_content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
