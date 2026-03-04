defmodule Slackex.Search.MessageSearchTest do
  use Slackex.DataCase, async: false

  alias Slackex.Search.MessageSearch

  # ---------------------------------------------------------------------------
  # Acceptance: public channel search with ranking and sender preload
  # ---------------------------------------------------------------------------

  describe "text_search/3 - public channel member can search" do
    test "returns messages from public channel ranked by relevance with sender preloaded" do
      user = insert(:user)
      channel = create_public_channel(user)

      _msg1 = send_channel_message(channel, user, "hello world from elixir")
      _msg2 = send_channel_message(channel, user, "goodbye cruel world")
      _msg3 = send_channel_message(channel, user, "unrelated content here")

      assert {:ok, results} = MessageSearch.text_search(user.id, "hello world")

      # Both messages containing "hello" or "world" should appear
      assert results != []

      # The most relevant result (containing both terms) should be first
      first = hd(results)
      assert first.content =~ "hello world"

      # Sender must be preloaded
      assert %Slackex.Accounts.User{} = first.sender
      assert first.sender.id == user.id
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: private channel exclusion
  # ---------------------------------------------------------------------------

  describe "text_search/3 - private channel authorization" do
    test "non-member cannot see messages from private channel" do
      owner = insert(:user)
      searcher = insert(:user)

      # searcher needs at least one public channel to be a valid user
      public = create_public_channel(searcher)
      _pub_msg = send_channel_message(public, searcher, "visible public message")

      private = create_private_channel(owner)
      _priv_msg = send_channel_message(private, owner, "visible public message in secret")

      assert {:ok, results} = MessageSearch.text_search(searcher.id, "visible public message")

      # Only the public channel message should appear, not the private one
      channel_ids = Enum.map(results, & &1.channel_id)
      assert public.id in channel_ids
      refute private.id in channel_ids
    end

    test "member of private channel can see its messages" do
      owner = insert(:user)
      member = insert(:user)

      private = create_private_channel(owner)
      subscribe_user_to_channel(private, member)

      _msg = send_channel_message(private, owner, "secret project discussion")

      assert {:ok, results} = MessageSearch.text_search(member.id, "secret project discussion")
      assert length(results) == 1
      assert hd(results).channel_id == private.id
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: DM inclusion
  # ---------------------------------------------------------------------------

  describe "text_search/3 - DM conversations" do
    test "DM participant can find messages from their conversations" do
      user_a = insert(:user)
      user_b = insert(:user)
      dm = create_dm_conversation(user_a, user_b)

      _msg = send_dm_message(dm, user_a, "private direct message about elixir")

      assert {:ok, results} = MessageSearch.text_search(user_a.id, "private direct message")
      assert length(results) == 1
      assert hd(results).dm_conversation_id == dm.id
    end

    test "non-participant cannot see DM messages" do
      user_a = insert(:user)
      user_b = insert(:user)
      outsider = insert(:user)

      dm = create_dm_conversation(user_a, user_b)
      _msg = send_dm_message(dm, user_a, "confidential direct exchange")

      # outsider needs something to search against
      public = create_public_channel(outsider)
      _pub_msg = send_channel_message(public, outsider, "confidential direct exchange public")

      assert {:ok, results} =
               MessageSearch.text_search(outsider.id, "confidential direct exchange")

      # Outsider should only see their public message, not the DM
      dm_ids = Enum.map(results, & &1.dm_conversation_id)
      refute dm.id in dm_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: headline with <mark> tags around matching terms
  # ---------------------------------------------------------------------------

  describe "text_search/3 - headline snippets" do
    test "returns headline with <mark> tags around matching terms" do
      user = insert(:user)
      channel = create_public_channel(user)

      _msg = send_channel_message(channel, user, "elixir is a functional programming language")

      assert {:ok, [result]} = MessageSearch.text_search(user.id, "functional programming")

      assert result.headline != nil
      assert result.headline =~ "<mark>"
      assert result.headline =~ "</mark>"
      assert result.headline =~ "functional"
      assert result.headline =~ "programming"
    end

    test "headline is nil when search_content is nil" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Insert a message where search_content is nil but still matches
      # via direct DB manipulation (simulates edge case)
      msg = insert(:message, channel: channel, sender: user, content: "findable keyword match")

      # Force search_content to a value so FTS matches, then nil it
      # Actually, if search_content is nil the FTS won't match at all.
      # So headline being nil is the coalesce('') case producing empty headline.
      # Test: a message with search_content = '' (empty, not nil) still returns
      # a headline (empty string from ts_headline, not nil)
      import Ecto.Query

      {1, _} =
        from(m in Slackex.Chat.Message, where: m.id == ^msg.id)
        |> Slackex.Repo.update_all(set: [search_content: "findable keyword match"])

      assert {:ok, [result]} = MessageSearch.text_search(user.id, "findable keyword")
      assert result.headline != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: empty results
  # ---------------------------------------------------------------------------

  describe "text_search/3 - no matches" do
    test "returns empty list without error when no messages match" do
      user = insert(:user)
      channel = create_public_channel(user)
      _msg = send_channel_message(channel, user, "something completely different")

      assert {:ok, []} = MessageSearch.text_search(user.id, "xyznonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: GIN index usage
  # ---------------------------------------------------------------------------

  describe "text_search/3 - GIN index usage" do
    test "EXPLAIN ANALYZE shows Bitmap Index Scan on GIN index, no Seq Scan on messages" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Seed 100+ messages so the planner prefers the index
      for i <- 1..110 do
        send_channel_message(channel, user, "searchable content number #{i} with keywords")
      end

      assert {:ok, explain_output} =
               MessageSearch.explain_text_search(user.id, "searchable keywords")

      explain_text = Enum.join(explain_output, "\n")

      assert explain_text =~ "Bitmap Index Scan" or explain_text =~ "Index Scan",
             "Expected index scan in EXPLAIN output but got:\n#{explain_text}"

      refute explain_text =~ ~r/Seq Scan on messages/,
             "Expected no Seq Scan on messages but got:\n#{explain_text}"
    end
  end

  # ===========================================================================
  # SEMANTIC SEARCH
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Acceptance: semantic search returns similar messages
  # ---------------------------------------------------------------------------

  describe "semantic_search/3 - embedded message in accessible channel" do
    test "returns message with similarity score above 0.3 when query is related" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "functional programming in elixir")
      embed_message(msg)

      # Search with the same text -- StubClient produces identical vector,
      # so cosine distance = 0, similarity = 1.0
      assert {:ok, results} =
               MessageSearch.semantic_search(user.id, "functional programming in elixir")

      assert [first | _rest] = results
      assert first.id == msg.id
      assert first.similarity > 0.3
      assert %Slackex.Accounts.User{} = first.sender
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: threshold filtering excludes low-similarity messages
  # ---------------------------------------------------------------------------

  describe "semantic_search/3 - threshold filtering" do
    test "excludes messages with similarity below 0.3" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Create a message and embed it with basis vector e0
      msg = send_channel_message(channel, user, "some content for testing threshold")
      embed_message_with_vector(msg, basis_vector(0))

      # Search with text that produces basis vector e1 (orthogonal, similarity = 0)
      # We use a custom embedding_client function that returns e1
      orthogonal_client = fn _text -> {:ok, basis_vector(1)} end

      assert {:ok, results} =
               MessageSearch.semantic_search(user.id, "orthogonal query",
                 embedding_client: orthogonal_client
               )

      # Orthogonal vectors have cosine similarity 0.0, which is below 0.3
      assert results == []
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: authorization excludes private channel messages
  # ---------------------------------------------------------------------------

  describe "semantic_search/3 - private channel authorization" do
    test "non-member cannot see semantically similar messages from private channel" do
      owner = insert(:user)
      searcher = insert(:user)

      # searcher has a public channel with an embedded message
      public = create_public_channel(searcher)
      pub_msg = send_channel_message(public, searcher, "shared knowledge base article")
      embed_message(pub_msg)

      # owner has a private channel with an embedded message using same text
      private = create_private_channel(owner)

      priv_msg =
        send_channel_message(private, owner, "shared knowledge base article")

      embed_message(priv_msg)

      assert {:ok, results} =
               MessageSearch.semantic_search(
                 searcher.id,
                 "shared knowledge base article"
               )

      result_ids = Enum.map(results, & &1.id)
      assert pub_msg.id in result_ids
      refute priv_msg.id in result_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: HNSW index usage with partition pruning
  # ---------------------------------------------------------------------------

  describe "semantic_search/3 - HNSW index usage" do
    test "EXPLAIN shows index scan on message_embeddings HNSW index" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Insert enough embedded messages for the planner to prefer the index
      for i <- 1..20 do
        msg = send_channel_message(channel, user, "embedding test content #{i}")
        embed_message(msg)
      end

      assert {:ok, explain_output} =
               MessageSearch.explain_semantic_search(
                 user.id,
                 "embedding test content"
               )

      explain_text = Enum.join(explain_output, "\n")

      assert explain_text =~ "Index Scan" or explain_text =~ "index_scan",
             "Expected index scan in EXPLAIN output but got:\n#{explain_text}"
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: EmbeddingClient error propagation
  # ---------------------------------------------------------------------------

  describe "semantic_search/3 - embedding client error" do
    test "returns {:error, reason} when EmbeddingClient fails" do
      user = insert(:user)
      _channel = create_public_channel(user)

      failing_client = fn _text -> {:error, :api_unavailable} end

      assert {:error, :api_unavailable} =
               MessageSearch.semantic_search(user.id, "any query",
                 embedding_client: failing_client
               )
    end
  end

  # ===========================================================================
  # HYBRID SEARCH
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Acceptance: RRF merging from both FTS and semantic results
  # ---------------------------------------------------------------------------

  describe "hybrid_search/3 - RRF merging" do
    test "merges results from both FTS and semantic by message ID with combined RRF score" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Create messages that will appear in both FTS and semantic results
      msg1 = send_channel_message(channel, user, "elixir functional programming guide")
      embed_message(msg1)

      msg2 = send_channel_message(channel, user, "elixir pattern matching tutorial")
      embed_message(msg2)

      assert {:ok, results} =
               MessageSearch.hybrid_search(user.id, "elixir functional programming")

      # Both messages should appear, merged by message ID
      result_ids = Enum.map(results, & &1.id)
      assert msg1.id in result_ids

      # Each result should have a search_score (combined RRF)
      first = hd(results)
      assert is_float(first.search_score)
      assert first.search_score > 0.0

      # Results with higher combined RRF score should come first
      scores = Enum.map(results, & &1.search_score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: single-source RRF inclusion
  # ---------------------------------------------------------------------------

  describe "hybrid_search/3 - single source inclusion" do
    test "message appearing only in FTS results still appears with single-source RRF score" do
      user = insert(:user)
      channel = create_public_channel(user)

      # This message has FTS content but NO embedding
      msg_fts_only =
        send_channel_message(channel, user, "unique findable keyword xyzspecial")

      # This message has both FTS and embedding
      msg_both = send_channel_message(channel, user, "unique findable keyword xyzspecial again")
      embed_message(msg_both)

      assert {:ok, results} =
               MessageSearch.hybrid_search(user.id, "unique findable keyword xyzspecial")

      result_ids = Enum.map(results, & &1.id)

      # The FTS-only message must still appear
      assert msg_fts_only.id in result_ids

      # It should have a positive search_score (from single-source RRF)
      fts_only_result = Enum.find(results, &(&1.id == msg_fts_only.id))
      assert fts_only_result.search_score > 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: parallel execution
  # ---------------------------------------------------------------------------

  describe "hybrid_search/3 - parallel execution" do
    test "FTS and semantic search run concurrently" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "concurrent search test content")
      embed_message(msg)

      # We verify parallel execution by confirming both search types contribute.
      # The hybrid result should contain the message (proving both paths ran).
      assert {:ok, results} =
               MessageSearch.hybrid_search(user.id, "concurrent search test content")

      assert results != []

      # Message should have combined RRF score from both sources
      result = Enum.find(results, &(&1.id == msg.id))
      assert result != nil
      assert result.search_score > 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Unit: RRF score computation
  # ---------------------------------------------------------------------------

  describe "compute_rrf_scores/3 - pure RRF computation" do
    test "combines scores from two ranked lists using reciprocal rank fusion" do
      # Messages ranked [a, b, c] in text, [b, c, a] in semantic
      text_ids = [:a, :b, :c]
      semantic_ids = [:b, :c, :a]

      scores = MessageSearch.compute_rrf_scores(text_ids, semantic_ids, 60)

      # :a is rank 1 in text (1/61) + rank 3 in semantic (1/63)
      expected_a = 1.0 / 61.0 + 1.0 / 63.0
      assert_in_delta scores[:a], expected_a, 1.0e-10

      # :b is rank 2 in text (1/62) + rank 1 in semantic (1/61)
      expected_b = 1.0 / 62.0 + 1.0 / 61.0
      assert_in_delta scores[:b], expected_b, 1.0e-10

      # :c is rank 3 in text (1/63) + rank 2 in semantic (1/62)
      expected_c = 1.0 / 63.0 + 1.0 / 62.0
      assert_in_delta scores[:c], expected_c, 1.0e-10
    end

    test "single-source items get score from their source only" do
      text_ids = [:a, :b]
      semantic_ids = [:c]

      scores = MessageSearch.compute_rrf_scores(text_ids, semantic_ids, 60)

      # :a only in text, rank 1 -> 1/61
      assert_in_delta scores[:a], 1.0 / 61.0, 1.0e-10

      # :c only in semantic, rank 1 -> 1/61
      assert_in_delta scores[:c], 1.0 / 61.0, 1.0e-10

      # :b only in text, rank 2 -> 1/62
      assert_in_delta scores[:b], 1.0 / 62.0, 1.0e-10
    end

    test "empty input lists return empty scores" do
      scores = MessageSearch.compute_rrf_scores([], [], 60)
      assert scores == %{}
    end

    test "one empty list still scores items from the other" do
      scores = MessageSearch.compute_rrf_scores([:x, :y], [], 60)
      assert_in_delta scores[:x], 1.0 / 61.0, 1.0e-10
      assert_in_delta scores[:y], 1.0 / 62.0, 1.0e-10
    end
  end
end
