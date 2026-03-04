defmodule Slackex.Search.MessageSearch do
  @moduledoc """
  Full-text and semantic search over messages with authorization enforcement.

  Provides two search modes:

  - **text_search/3**: PostgreSQL tsvector/tsquery on the `search_content` column,
    ranked by `ts_rank`.
  - **semantic_search/3**: pgvector cosine similarity against pre-computed
    message embeddings, filtered by a configurable similarity threshold.

  Both modes enforce authorization so users only see messages they are
  authorized to access:

  - Public channels: visible to all users
  - Private channels: visible only to subscribed members
  - DM conversations: visible only to participants

  Authorization is enforced via EXISTS subqueries to avoid row duplication
  that would corrupt ranking.
  """

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}
  alias Slackex.Repo

  @default_limit 20
  @default_similarity_threshold 0.3
  @rrf_k 60
  @hybrid_task_timeout 5_000

  @doc """
  Searches messages matching the given query text, scoped by authorization.

  Returns `{:ok, [Message.t()]}` with sender preloaded, ranked by relevance.

  ## Options

    * `:limit` - maximum results (default #{@default_limit})
    * `:offset` - pagination offset (default 0)
    * `:channel_id` - scope search to a specific channel

  """
  @spec text_search(integer(), String.t(), keyword()) :: {:ok, [Ecto.Schema.t()]}
  def text_search(user_id, query, opts \\ []) do
    results =
      build_search_query(user_id, query, opts)
      |> Repo.all()

    {:ok, results}
  end

  @doc """
  Runs EXPLAIN ANALYZE on the text_search query for index verification.

  Returns `{:ok, [String.t()]}` with the EXPLAIN output lines.
  """
  @spec explain_text_search(integer(), String.t(), keyword()) :: {:ok, [String.t()]}
  def explain_text_search(user_id, query, opts \\ []) do
    search_query = build_search_query(user_id, query, opts)
    {explain_sql, explain_params} = Repo.to_sql(:all, search_query)
    explain_sql = "EXPLAIN ANALYZE " <> explain_sql

    # Disable seq scan to verify the GIN index is usable by the planner.
    # This is only called from tests; production queries let the planner decide.
    _ = Repo.query!("SET LOCAL enable_seqscan = off")

    case Repo.query(explain_sql, explain_params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [line] -> line end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Searches messages by cosine similarity against pre-computed embeddings.

  Generates an embedding for the query text, then finds messages whose
  embedding vectors are within the similarity threshold (default 0.3).
  Results are ordered by similarity descending (most similar first).

  Returns `{:ok, [Message.t()]}` with `:similarity` virtual field populated
  and `:sender` preloaded, or `{:error, reason}` if embedding generation fails.

  ## Options

    * `:limit` - maximum results (default #{@default_limit})
    * `:offset` - pagination offset (default 0)
    * `:channel_id` - scope search to a specific channel
    * `:threshold` - minimum similarity score (default #{@default_similarity_threshold})
    * `:embedding_client` - function `(String.t() -> {:ok, [float()]} | {:error, term()})`
      for dependency injection (default: `EmbeddingClient.generate/1`)

  """
  @spec semantic_search(integer(), String.t(), keyword()) ::
          {:ok, [Ecto.Schema.t()]} | {:error, term()}
  def semantic_search(user_id, query, opts \\ []) do
    generate_fn = Keyword.get(opts, :embedding_client, &EmbeddingClient.generate/1)

    case generate_fn.(query) do
      {:ok, query_vector} ->
        results =
          build_semantic_query(user_id, query_vector, opts)
          |> Repo.all()

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs full-text and semantic search in parallel, merging results using
  Reciprocal Rank Fusion (RRF) with k=#{@rrf_k}.

  Each result receives a `:search_score` virtual field containing its combined
  RRF score. Messages appearing in both result sets receive the sum of their
  individual RRF scores; messages in only one set receive a single-source score.

  Returns `{:ok, [Message.t()]}` sorted by combined RRF score descending,
  or `{:error, reason}` if embedding generation fails.

  ## Options

    * `:limit` - maximum results after merge (default #{@default_limit})
    * `:offset` - pagination offset after merge (default 0)
    * `:channel_id` - scope search to a specific channel
    * `:threshold` - minimum similarity for semantic results (default #{@default_similarity_threshold})
    * `:embedding_client` - embedding generation function for DI

  """
  @spec hybrid_search(integer(), String.t(), keyword()) ::
          {:ok, [Ecto.Schema.t()]} | {:error, term()}
  def hybrid_search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    # Fetch a large candidate set from each source to allow proper RRF ranking.
    source_opts = Keyword.merge(opts, limit: limit * 5, offset: 0)

    text_task = Task.async(fn -> text_search(user_id, query, source_opts) end)
    semantic_task = Task.async(fn -> semantic_search(user_id, query, source_opts) end)

    text_result = Task.await(text_task, @hybrid_task_timeout)
    semantic_result = Task.await(semantic_task, @hybrid_task_timeout)

    case {text_result, semantic_result} do
      {{:ok, text_messages}, {:ok, semantic_messages}} ->
        merged = merge_with_rrf(text_messages, semantic_messages, limit, offset)
        {:ok, merged}

      {{:ok, text_messages}, {:error, _reason}} ->
        # Semantic failed, fall back to text-only with RRF scores
        merged = merge_with_rrf(text_messages, [], limit, offset)
        {:ok, merged}

      {{:error, _reason}, {:ok, semantic_messages}} ->
        merged = merge_with_rrf([], semantic_messages, limit, offset)
        {:ok, merged}

      {{:error, reason}, {:error, _}} ->
        {:error, reason}
    end
  end

  @doc """
  Computes RRF scores for items appearing in two ranked lists.

  Returns a map of `id => combined_rrf_score`. Items in both lists receive
  the sum of their reciprocal rank scores; items in only one list receive
  a single-source score.

  ## Parameters

    * `text_ids` - ordered list of IDs from text search (rank 1 first)
    * `semantic_ids` - ordered list of IDs from semantic search (rank 1 first)
    * `k` - RRF constant (typically 60)

  """
  @spec compute_rrf_scores([term()], [term()], pos_integer()) :: %{term() => float()}
  def compute_rrf_scores(text_ids, semantic_ids, k) do
    text_scores = rank_to_rrf_map(text_ids, k)
    semantic_scores = rank_to_rrf_map(semantic_ids, k)

    Map.merge(text_scores, semantic_scores, fn _id, text_score, semantic_score ->
      text_score + semantic_score
    end)
  end

  @doc """
  Runs EXPLAIN ANALYZE on the semantic_search query for index verification.

  Returns `{:ok, [String.t()]}` with the EXPLAIN output lines.
  """
  @spec explain_semantic_search(integer(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def explain_semantic_search(user_id, query, opts \\ []) do
    generate_fn = Keyword.get(opts, :embedding_client, &EmbeddingClient.generate/1)

    case generate_fn.(query) do
      {:ok, query_vector} ->
        search_query = build_semantic_query(user_id, query_vector, opts)
        {explain_sql, explain_params} = Repo.to_sql(:all, search_query)
        explain_sql = "EXPLAIN ANALYZE " <> explain_sql

        _ = Repo.query!("SET LOCAL enable_seqscan = off")

        case Repo.query(explain_sql, explain_params) do
          {:ok, %{rows: rows}} ->
            {:ok, Enum.map(rows, fn [line] -> line end)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Query construction
  # ---------------------------------------------------------------------------

  defp build_search_query(user_id, query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    from(m in Message,
      where:
        fragment(
          "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
          m.search_content,
          ^query
        ),
      where: is_nil(m.deleted_at),
      where: ^build_authorization_condition(user_id, opts),
      order_by:
        fragment(
          "ts_rank(to_tsvector('english', coalesce(?, '')), plainto_tsquery('english', ?)) DESC",
          m.search_content,
          ^query
        ),
      select_merge: %{
        headline:
          type(
            fragment(
              "ts_headline('english', coalesce(?, ''), plainto_tsquery('english', ?), 'StartSel=<mark>, StopSel=</mark>, MaxWords=40, MinWords=15')",
              m.search_content,
              ^query
            ),
            :string
          )
      },
      limit: ^limit,
      offset: ^offset,
      preload: [:sender]
    )
  end

  defp build_semantic_query(user_id, query_vector, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)
    threshold = Keyword.get(opts, :threshold, @default_similarity_threshold)
    vector_param = Pgvector.new(query_vector)

    from(m in Message,
      join: me in MessageEmbedding,
      on: me.message_id == m.id and me.message_inserted_at == m.inserted_at,
      where: is_nil(m.deleted_at),
      where: ^build_authorization_condition(user_id, opts),
      where:
        fragment(
          "(1.0 - (? <=> ?::vector)) > ?::float8",
          me.embedding,
          ^vector_param,
          ^threshold
        ),
      order_by:
        fragment(
          "? <=> ?::vector",
          me.embedding,
          ^vector_param
        ),
      select_merge: %{
        similarity:
          type(
            fragment(
              "(1.0 - (? <=> ?::vector))",
              me.embedding,
              ^vector_param
            ),
            :float
          )
      },
      limit: ^limit,
      offset: ^offset,
      preload: [:sender]
    )
  end

  defp build_authorization_condition(user_id, opts) do
    case Keyword.get(opts, :channel_id) do
      nil -> global_authorization_filter(user_id)
      channel_id -> scoped_channel_authorization_filter(user_id, channel_id)
    end
  end

  # User can see messages from:
  # 1. Public channels (is_private = false)
  # 2. Private channels they are subscribed to
  # 3. DM conversations they participate in
  defp global_authorization_filter(user_id) do
    dynamic(
      [m],
      ^public_channel_condition() or
        ^private_channel_member_condition(user_id) or
        ^dm_participant_condition(user_id)
    )
  end

  defp scoped_channel_authorization_filter(user_id, channel_id) do
    dynamic(
      [m],
      m.channel_id == ^channel_id and
        (fragment(
           "EXISTS (SELECT 1 FROM channels c WHERE c.id = ? AND c.is_private = false)",
           m.channel_id
         ) or
           fragment(
             """
             EXISTS (
               SELECT 1 FROM subscriptions s
               WHERE s.channel_id = ? AND s.user_id = ?
             )
             """,
             m.channel_id,
             ^user_id
           ))
    )
  end

  defp public_channel_condition do
    dynamic(
      [m],
      fragment(
        """
        (
          ? IS NOT NULL AND EXISTS (
            SELECT 1 FROM channels c
            WHERE c.id = ? AND c.is_private = false
          )
        )
        """,
        m.channel_id,
        m.channel_id
      )
    )
  end

  defp private_channel_member_condition(user_id) do
    dynamic(
      [m],
      fragment(
        """
        (
          ? IS NOT NULL AND EXISTS (
            SELECT 1 FROM channels c
            INNER JOIN subscriptions s ON s.channel_id = c.id
            WHERE c.id = ? AND c.is_private = true
              AND s.user_id = ?
          )
        )
        """,
        m.channel_id,
        m.channel_id,
        ^user_id
      )
    )
  end

  defp dm_participant_condition(user_id) do
    dynamic(
      [m],
      fragment(
        """
        (
          ? IS NOT NULL AND EXISTS (
            SELECT 1 FROM dm_conversations d
            WHERE d.id = ? AND (d.user_a_id = ? OR d.user_b_id = ?)
          )
        )
        """,
        m.dm_conversation_id,
        m.dm_conversation_id,
        ^user_id,
        ^user_id
      )
    )
  end

  # ---------------------------------------------------------------------------
  # RRF merge helpers
  # ---------------------------------------------------------------------------

  defp merge_with_rrf(text_messages, semantic_messages, limit, offset) do
    text_ids = Enum.map(text_messages, & &1.id)
    semantic_ids = Enum.map(semantic_messages, & &1.id)

    rrf_scores = compute_rrf_scores(text_ids, semantic_ids, @rrf_k)

    # Build a map of id => message, preferring semantic (has :similarity) over text
    messages_by_id =
      (text_messages ++ semantic_messages)
      |> Enum.reduce(%{}, fn msg, acc ->
        Map.put_new(acc, msg.id, msg)
      end)

    rrf_scores
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.map(fn {id, score} ->
      messages_by_id
      |> Map.fetch!(id)
      |> Map.put(:search_score, score)
    end)
  end

  defp rank_to_rrf_map(ids, k) do
    ids
    |> Enum.with_index(1)
    |> Map.new(fn {id, rank} -> {id, 1.0 / (k + rank)} end)
  end
end
