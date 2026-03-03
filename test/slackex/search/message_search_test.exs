defmodule Slackex.Search.MessageSearchTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Search.MessageSearch

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_public_channel(creator) do
    channel = insert(:channel, creator: creator, is_private: false)
    insert(:subscription, user: creator, channel: channel, role: "owner")
    channel
  end

  defp create_private_channel(creator) do
    channel = insert(:channel, creator: creator, is_private: true)
    insert(:subscription, user: creator, channel: channel, role: "owner")
    channel
  end

  defp subscribe_user(channel, user) do
    insert(:subscription, user: user, channel: channel, role: "member")
  end

  defp send_channel_message(channel, sender, content) do
    {:ok, message} = Chat.send_message(channel.id, sender.id, content)
    message
  end

  defp send_dm_message(dm, sender, content) do
    {:ok, message} = Chat.send_dm(dm.id, sender.id, content)
    message
  end

  defp create_dm_conversation(user_a, user_b) do
    {a, b} = if user_a.id < user_b.id, do: {user_a, user_b}, else: {user_b, user_a}

    %Slackex.Chat.DMConversation{}
    |> Ecto.Changeset.change(%{user_a_id: a.id, user_b_id: b.id})
    |> Repo.insert!()
  end

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
      assert length(results) >= 1

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
      subscribe_user(private, member)

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
  # Helpers: semantic search
  # ---------------------------------------------------------------------------

  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}

  defp embed_message(message) do
    content = message.content || message.search_content || ""
    {:ok, vector} = EmbeddingClient.generate(content)
    content_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %MessageEmbedding{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: Pgvector.new(vector),
      content_hash: content_hash,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Repo.insert!()
  end

  defp embed_message_with_vector(message, vector) do
    content = message.content || message.search_content || ""
    content_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %MessageEmbedding{
      message_id: message.id,
      message_inserted_at: message.inserted_at,
      channel_id: message.channel_id,
      dm_conversation_id: message.dm_conversation_id,
      embedding: Pgvector.new(vector),
      content_hash: content_hash,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Repo.insert!()
  end

  # Builds a unit vector with value 1.0 at the given index, 0.0 elsewhere.
  # Useful for creating orthogonal vectors with known cosine similarity.
  defp basis_vector(index, dimensions \\ 1536) do
    Enum.map(0..(dimensions - 1), fn i ->
      if i == index, do: 1.0, else: 0.0
    end)
  end

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
end
