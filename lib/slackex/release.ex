defmodule Slackex.Release do
  @moduledoc """
  Tasks that can be run without Mix installed (i.e. in production releases).

  Usage:

      /app/bin/slackex eval "Slackex.Release.migrate()"
      /app/bin/slackex eval "Slackex.Release.rollback(Slackex.Repo, 20240101000000)"
      /app/bin/slackex eval "Slackex.Release.backfill_embeddings()"
      /app/bin/slackex eval "Slackex.Release.backfill_embeddings(force: true)"
  """

  @app :slackex

  require Logger

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}

  @batch_size 50

  def migrate do
    _ = load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    _ = load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Backfills vector embeddings for all existing messages.

  Populates missing `search_content` from decrypted content, then generates
  embeddings synchronously. Requires the full application to be running
  (starts it automatically).

  ## Options

    * `force: true` — delete all existing embeddings before re-embedding
  """
  def backfill_embeddings(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(@app)

    repo = Slackex.Repo

    if Keyword.get(opts, :force, false) do
      {count, _} = repo.delete_all(MessageEmbedding)
      Logger.info("[BackfillEmbeddings] Deleted #{count} existing embeddings (force: true)")
    end

    wait_for_embedding_serving()

    sc_count = do_backfill_search_content(repo)

    if sc_count > 0,
      do: Logger.info("[BackfillEmbeddings] Populated search_content for #{sc_count} messages")

    embed_count = do_generate_embeddings(repo)
    Logger.info("[BackfillEmbeddings] Done — generated #{embed_count} embeddings")
  end

  # ---------------------------------------------------------------------------
  # Embedding backfill internals
  # ---------------------------------------------------------------------------

  defp do_generate_embeddings(repo) do
    messages =
      from(m in Message,
        left_join: me in MessageEmbedding,
        on: me.message_id == m.id,
        where: is_nil(m.deleted_at),
        where: is_nil(me.message_id),
        where: not is_nil(m.search_content),
        select: m,
        order_by: [asc: m.id]
      )
      |> repo.all()

    Logger.info("[BackfillEmbeddings] Found #{length(messages)} messages needing embeddings")

    messages
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      texts = Enum.map(batch, & &1.search_content)

      case EmbeddingClient.generate_batch(texts) do
        {:ok, vectors} ->
          batch
          |> Enum.zip(vectors)
          |> Enum.each(fn {msg, vector} -> upsert_embedding(repo, msg, vector) end)

          count = length(batch)
          Logger.info("[BackfillEmbeddings]   embedded #{count} messages (#{acc + count} total)")
          acc + count

        {:error, reason} ->
          Logger.error("[BackfillEmbeddings]   batch failed: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp upsert_embedding(repo, message, vector) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = :crypto.hash(:sha256, message.search_content) |> Base.encode16(case: :lower)

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
    |> repo.insert(
      on_conflict: {:replace, [:embedding, :content_hash, :inserted_at]},
      conflict_target: :message_id
    )
  end

  defp do_backfill_search_content(repo) do
    messages =
      from(m in Message,
        where: is_nil(m.search_content),
        where: is_nil(m.deleted_at)
      )
      |> repo.all()

    Enum.each(messages, fn msg ->
      if msg.content do
        from(m in Message, where: m.id == ^msg.id)
        |> repo.update_all(set: [search_content: msg.content])
      end
    end)

    length(messages)
  end

  defp wait_for_embedding_serving do
    case Application.get_env(:slackex, :embedding_client) do
      Slackex.Embeddings.BumblebeeClient ->
        Logger.info("[BackfillEmbeddings] Waiting for EmbeddingServing to load model...")
        do_wait_for_serving(120)

      _other ->
        :ok
    end
  end

  defp do_wait_for_serving(0) do
    Logger.error("[BackfillEmbeddings] EmbeddingServing did not become ready in time")
    raise "EmbeddingServing timeout"
  end

  defp do_wait_for_serving(retries) do
    case GenServer.call(Slackex.Embeddings.EmbeddingServing, :get_state, 5_000) do
      %{status: :ready} ->
        Logger.info("[BackfillEmbeddings] EmbeddingServing ready")

      _ ->
        Process.sleep(1_000)
        do_wait_for_serving(retries - 1)
    end
  catch
    :exit, _ ->
      Process.sleep(1_000)
      do_wait_for_serving(retries - 1)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.load(@app)
  end
end
