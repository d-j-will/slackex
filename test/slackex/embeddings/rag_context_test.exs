defmodule Slackex.Embeddings.RAGContextTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding, RAGContext}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_public_channel(creator) do
    channel = insert(:channel, creator: creator, is_private: false)
    insert(:subscription, user: creator, channel: channel, role: "owner")
    channel
  end

  defp send_channel_message(channel, sender, content) do
    {:ok, message} = Chat.send_message(channel.id, sender.id, content)
    message
  end

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

  # ---------------------------------------------------------------------------
  # Acceptance: formatted output with "[YYYY-MM-DD HH:MM] username: content"
  # ---------------------------------------------------------------------------

  describe "retrieve/2 - formatted output" do
    test "returns lines formatted as [YYYY-MM-DD HH:MM] username: content" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "hello from semantic search")
      embed_message(msg)

      assert {:ok, context, count} =
               RAGContext.retrieve("hello from semantic search", user_id: user.id)

      assert count >= 1

      # Each line should match the expected format
      lines = String.split(context, "\n", trim: true)
      assert length(lines) >= 1

      for line <- lines do
        assert Regex.match?(
                 ~r/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] .+: .+$/,
                 line
               ),
               "Line does not match expected format: #{inspect(line)}"
      end

      # The first line should contain our message content
      first_line = hd(lines)
      assert first_line =~ "hello from semantic search"
      assert first_line =~ user.username
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: token truncation respects max_tokens and never cuts mid-line
  # ---------------------------------------------------------------------------

  describe "retrieve/2 - token truncation" do
    test "truncates to fit within default max_tokens (4000) without cutting mid-line" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Create many messages to exceed the token budget
      # Each message ~100 chars formatted, 20 messages = ~2000 chars
      # With max_tokens=4000 and 4 chars/token = 16000 chars budget, 20 should fit
      for i <- 1..20 do
        msg =
          send_channel_message(
            channel,
            user,
            "message number #{i} with enough content to be meaningful for search"
          )

        embed_message(msg)
      end

      assert {:ok, context, count} =
               RAGContext.retrieve(
                 "message number with enough content",
                 user_id: user.id,
                 limit: 20
               )

      assert count >= 1
      assert is_binary(context)
      assert byte_size(context) > 0

      # Verify no line is cut mid-way: every line should be complete
      lines = String.split(context, "\n", trim: true)

      for line <- lines do
        assert Regex.match?(
                 ~r/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] .+: .+$/,
                 line
               ),
               "Truncated line found: #{inspect(line)}"
      end
    end

    test "with small max_tokens, truncates and includes fewer lines" do
      user = insert(:user)
      channel = create_public_channel(user)

      # Create messages that collectively exceed a small token budget
      for i <- 1..10 do
        msg =
          send_channel_message(
            channel,
            user,
            "semantic search result number #{i} with padding text"
          )

        embed_message(msg)
      end

      # max_tokens=10 => ~40 chars, which is roughly one formatted line
      assert {:ok, context_small, count_small} =
               RAGContext.retrieve(
                 "semantic search result number",
                 user_id: user.id,
                 max_tokens: 10,
                 limit: 10
               )

      assert {:ok, context_large, count_large} =
               RAGContext.retrieve(
                 "semantic search result number",
                 user_id: user.id,
                 max_tokens: 4000,
                 limit: 10
               )

      assert count_small <= count_large
      assert byte_size(context_small) <= byte_size(context_large)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: custom max_tokens override
  # ---------------------------------------------------------------------------

  describe "retrieve/2 - custom max_tokens" do
    test "respects max_tokens override" do
      user = insert(:user)
      channel = create_public_channel(user)

      for i <- 1..5 do
        msg =
          send_channel_message(
            channel,
            user,
            "custom token budget test message #{i} with extra words"
          )

        embed_message(msg)
      end

      # Use a very small budget: 25 tokens = ~100 chars
      assert {:ok, context, count} =
               RAGContext.retrieve(
                 "custom token budget test message",
                 user_id: user.id,
                 max_tokens: 25,
                 limit: 5
               )

      # The context should be constrained
      max_chars = 25 * 4
      assert byte_size(context) <= max_chars
      assert count >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: empty results
  # ---------------------------------------------------------------------------

  describe "retrieve/2 - no matching messages" do
    test "returns empty string and zero count when no messages match" do
      user = insert(:user)
      _channel = create_public_channel(user)

      assert {:ok, "", 0} =
               RAGContext.retrieve(
                 "xyznonexistentquerythatwontmatch",
                 user_id: user.id
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: error propagation from semantic search
  # ---------------------------------------------------------------------------

  describe "retrieve/2 - error propagation" do
    test "returns {:error, reason} when semantic search fails" do
      user = insert(:user)
      _channel = create_public_channel(user)

      failing_client = fn _text -> {:error, :embedding_api_down} end

      assert {:error, :embedding_api_down} =
               RAGContext.retrieve(
                 "any query",
                 user_id: user.id,
                 embedding_client: failing_client
               )
    end
  end
end
