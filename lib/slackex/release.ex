defmodule Slackex.Release do
  @moduledoc """
  Tasks that can be run without Mix installed (i.e. in production releases).

  Usage:

      /app/bin/slackex eval "Slackex.Release.migrate()"
      /app/bin/slackex eval "Slackex.Release.rollback(Slackex.Repo, 20240101000000)"
      /app/bin/slackex eval "Slackex.Release.backfill_embeddings()"
      /app/bin/slackex eval "Slackex.Release.backfill_embeddings(force: true)"
      /app/bin/slackex eval "Slackex.Release.decode_html_entities()"
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

  @doc """
  Decodes HTML entities in existing messages stored before v0.5.82.

  Phase 2 of the markdown rendering architecture cleanup. Messages processed
  through `HtmlSanitizeEx.strip_tags/1` had special characters encoded
  (`>` to `&gt;`, `<` to `&lt;`, etc.). Now that `strip_tags` is removed,
  this task reverses those encodings in both the encrypted `content` field
  and the plaintext `search_content` column.

  Runs a sampling checkpoint (10 random affected messages) before bulk
  processing to verify correctness. Processes in batches of 100.

  Idempotent: the query filters on `search_content` containing HTML entities,
  so already-clean messages are skipped. Running `unescape_html/1` on clean
  content is also a no-op.

  After this task completes, run `backfill_embeddings(force: true)` to
  regenerate embeddings from the clean `search_content`.
  """
  def decode_html_entities do
    {:ok, _} = Application.ensure_all_started(@app)

    repo = Slackex.Repo

    affected_count = count_affected_messages(repo)
    Logger.info("[DecodeEntities] Found #{affected_count} messages with HTML entities")

    if affected_count == 0 do
      Logger.info("[DecodeEntities] No messages need decoding — done")
    else
      case run_sampling_checkpoint(repo) do
        :ok ->
          do_decode_all(repo)

        {:error, reason} ->
          Logger.error("[DecodeEntities] Sampling checkpoint failed: #{reason} — aborting")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # HTML entity decode internals
  # ---------------------------------------------------------------------------

  @decode_batch_size 100

  defp count_affected_messages(repo) do
    from(m in Message,
      where: is_nil(m.deleted_at),
      where:
        like(m.search_content, "%&gt;%") or
          like(m.search_content, "%&lt;%") or
          like(m.search_content, "%&amp;%")
    )
    |> repo.aggregate(:count)
  end

  defp affected_messages_query do
    from(m in Message,
      where: is_nil(m.deleted_at),
      where:
        like(m.search_content, "%&gt;%") or
          like(m.search_content, "%&lt;%") or
          like(m.search_content, "%&amp;%"),
      order_by: [asc: m.id]
    )
  end

  defp run_sampling_checkpoint(repo) do
    sample_size = 10

    samples =
      from(m in Message,
        where: is_nil(m.deleted_at),
        where:
          like(m.search_content, "%&gt;%") or
            like(m.search_content, "%&lt;%") or
            like(m.search_content, "%&amp;%"),
        order_by: fragment("RANDOM()"),
        limit: ^sample_size
      )
      |> repo.all()

    if samples == [] do
      :ok
    else
      verify_samples(repo, samples)
    end
  end

  defp verify_samples(repo, samples) do
    results =
      Enum.map(samples, fn message ->
        expected_content = unescape_html(message.content)
        expected_search = unescape_html(message.search_content)

        # Write the decoded values, reload through Cloak decrypt, verify roundtrip,
        # then revert so the bulk pass processes all messages in a single clean pass.
        message
        |> Ecto.Changeset.change(%{content: expected_content, search_content: expected_search})
        |> repo.update()

        reloaded = repo.get!(Message, message.id)

        verified =
          reloaded.content == expected_content and reloaded.search_content == expected_search

        # Always revert — sampling is a verification step, not a processing step.
        # The bulk pass will handle all messages uniformly.
        revert_changeset =
          Ecto.Changeset.change(reloaded, %{
            content: message.content,
            search_content: message.search_content
          })

        repo.update(revert_changeset)

        if verified, do: :ok, else: {:error, message.id}
      end)

    verified = Enum.count(results, &(&1 == :ok))
    total = length(samples)

    Logger.info(
      "[DecodeEntities] Sampling checkpoint: #{verified}/#{total} verified successfully"
    )

    if verified == total do
      :ok
    else
      failed_ids =
        results
        |> Enum.filter(&(&1 != :ok))
        |> Enum.map(fn {:error, id} -> id end)

      {:error, "#{total - verified} samples failed verification: #{inspect(failed_ids)}"}
    end
  end

  defp do_decode_all(repo) do
    total =
      affected_messages_query()
      |> repo.all()
      |> Enum.chunk_every(@decode_batch_size)
      |> Enum.reduce(0, fn batch, acc ->
        decoded = decode_batch(repo, batch)
        progress = acc + decoded
        Logger.info("[DecodeEntities]   decoded #{decoded} messages (#{progress} total)")
        progress
      end)

    Logger.info("[DecodeEntities] Done — decoded #{total} messages")
  end

  defp decode_batch(repo, batch) do
    Enum.each(batch, fn message ->
      decoded_content = unescape_html(message.content)
      decoded_search = unescape_html(message.search_content)

      message
      |> Ecto.Changeset.change(%{content: decoded_content, search_content: decoded_search})
      |> repo.update()
    end)

    length(batch)
  end

  # Reverses the HTML entity encoding applied by HtmlSanitizeEx.strip_tags/1.
  # Order matters: `&amp;` is replaced LAST so that double-encoded entities
  # like `&amp;gt;` (from a user who typed literal `&gt;`) remain as `&gt;`
  # rather than being decoded all the way to `>`.
  defp unescape_html(nil), do: nil

  defp unescape_html(text) do
    text
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
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
      acc + embed_batch(repo, batch, acc)
    end)
  end

  defp embed_batch(repo, batch, acc) do
    texts = Enum.map(batch, & &1.search_content)

    case EmbeddingClient.generate_batch(texts) do
      {:ok, vectors} ->
        Enum.zip(batch, vectors)
        |> Enum.each(fn {msg, vector} -> upsert_embedding(repo, msg, vector) end)

        count = length(batch)
        Logger.info("[BackfillEmbeddings]   embedded #{count} messages (#{acc + count} total)")
        count

      {:error, reason} ->
        Logger.error("[BackfillEmbeddings]   batch failed: #{inspect(reason)}")
        0
    end
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
