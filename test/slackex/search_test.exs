defmodule Slackex.SearchTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Embeddings.{EmbeddingClient, MessageEmbedding}
  alias Slackex.Search

  setup do
    FunWithFlags.enable(:message_search)
    :ok
  end

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
  # Acceptance: mode dispatch - :text mode only runs FTS
  # ---------------------------------------------------------------------------

  describe "search_messages/3 - mode :text" do
    test "dispatches to text search only, no embedding generation" do
      user = insert(:user)
      channel = create_public_channel(user)

      _msg = send_channel_message(channel, user, "text mode dispatch testing")

      assert {:ok, results} =
               Search.search_messages(user.id, "text mode dispatch testing", mode: :text)

      assert length(results) >= 1
      assert hd(results).content =~ "text mode dispatch"
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: mode dispatch - :semantic
  # ---------------------------------------------------------------------------

  describe "search_messages/3 - mode :semantic" do
    test "dispatches to semantic search" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "semantic mode dispatch testing")
      embed_message(msg)

      assert {:ok, results} =
               Search.search_messages(user.id, "semantic mode dispatch testing", mode: :semantic)

      assert length(results) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: mode dispatch - :hybrid (default)
  # ---------------------------------------------------------------------------

  describe "search_messages/3 - mode :hybrid (default)" do
    test "dispatches to hybrid search by default" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "hybrid default dispatch testing")
      embed_message(msg)

      # No mode specified -- should default to :hybrid
      assert {:ok, results} =
               Search.search_messages(user.id, "hybrid default dispatch testing")

      assert length(results) >= 1

      # Hybrid results have search_score
      first = hd(results)
      assert is_float(first.search_score)
      assert first.search_score > 0.0
    end

    test "explicit :hybrid mode dispatches to hybrid search" do
      user = insert(:user)
      channel = create_public_channel(user)

      msg = send_channel_message(channel, user, "explicit hybrid mode testing")
      embed_message(msg)

      assert {:ok, results} =
               Search.search_messages(user.id, "explicit hybrid mode testing", mode: :hybrid)

      assert length(results) >= 1
      assert is_float(hd(results).search_score)
    end
  end
end
