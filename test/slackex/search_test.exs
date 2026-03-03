defmodule Slackex.SearchTest do
  use Slackex.DataCase, async: false

  alias Slackex.Search

  setup do
    FunWithFlags.enable(:message_search)
    :ok
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

      assert results != []
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

      assert results != []
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

      assert results != []

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

      assert results != []
      assert is_float(hd(results).search_score)
    end
  end
end
