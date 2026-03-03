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
end
