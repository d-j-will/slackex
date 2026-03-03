defmodule Slackex.Search.MessageSearch do
  @moduledoc """
  Full-text search over messages with authorization enforcement.

  Uses PostgreSQL tsvector/tsquery on the `search_content` column (plaintext
  companion to the encrypted `encrypted_content` column). Results are ranked
  by `ts_rank` and filtered so users only see messages they are authorized
  to access:

  - Public channels: visible to all users
  - Private channels: visible only to subscribed members
  - DM conversations: visible only to participants

  Authorization is enforced via EXISTS subqueries to avoid row duplication
  that would corrupt ts_rank ordering.
  """

  import Ecto.Query

  alias Slackex.Chat.Message
  alias Slackex.Repo

  @default_limit 20

  @doc """
  Searches messages matching the given query text, scoped by authorization.

  Returns `{:ok, [Message.t()]}` with sender preloaded, ranked by relevance.

  ## Options

    * `:limit` - maximum results (default #{@default_limit})
    * `:offset` - pagination offset (default 0)
    * `:channel_id` - scope search to a specific channel

  """
  @spec text_search(integer(), String.t(), keyword()) :: {:ok, [Message.t()]}
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
    Repo.query!("SET LOCAL enable_seqscan = off")

    case Repo.query(explain_sql, explain_params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [line] -> line end)}

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
      limit: ^limit,
      offset: ^offset,
      preload: [:sender]
    )
  end

  defp build_authorization_condition(user_id, opts) do
    case Keyword.get(opts, :channel_id) do
      nil ->
        # User can see messages from:
        # 1. Public channels (is_private = false)
        # 2. Private channels they are subscribed to
        # 3. DM conversations they participate in
        dynamic(
          [m],
          # Public channel messages
          # Private channel messages where user is subscribed
          # DM messages where user is a participant
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
          ) or
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
            ) or
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

      channel_id ->
        # Scoped to a specific channel -- still enforce authorization
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
  end
end
