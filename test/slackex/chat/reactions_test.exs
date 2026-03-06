defmodule Slackex.Chat.ReactionsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    user = insert(:user)
    other_user = insert(:user)
    channel = insert(:channel) |> with_subscription(user)
    message = insert(:message, sender: user, channel: channel)
    %{user: user, other_user: other_user, channel: channel, message: message}
  end

  describe "toggle_reaction/3" do
    test "adds a reaction when none exists", %{user: user, message: message} do
      assert {:ok, {:added, reaction}} = Chat.toggle_reaction(message.id, user.id, "👍")
      assert reaction.emoji == "👍"
      assert reaction.user_id == user.id
      assert reaction.message_id == message.id
    end

    test "removes a reaction when clicking the same emoji", %{user: user, message: message} do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      assert {:ok, {:removed, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
    end

    test "swaps reaction when user picks a different emoji", %{user: user, message: message} do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      assert {:ok, {:swapped, new, old}} = Chat.toggle_reaction(message.id, user.id, "❤️")
      assert new.emoji == "❤️"
      assert old.emoji == "👍"

      # Only the new emoji remains in the DB
      result = Chat.list_reactions([message.id])
      reactions = result[message.id]
      assert length(reactions) == 1
      assert hd(reactions).emoji == "❤️"
      assert hd(reactions).count == 1
    end

    test "user can only have one reaction per message", %{user: user, message: message} do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:swapped, _, _}} = Chat.toggle_reaction(message.id, user.id, "😂")
      {:ok, {:swapped, _, _}} = Chat.toggle_reaction(message.id, user.id, "❤️")

      result = Chat.list_reactions([message.id])
      reactions = result[message.id]
      assert length(reactions) == 1
      assert hd(reactions).emoji == "❤️"
    end

    test "different users can react with same emoji", %{
      user: user,
      other_user: other_user,
      message: message
    } do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, other_user.id, "👍")

      result = Chat.list_reactions([message.id])
      thumbs = Enum.find(result[message.id], &(&1.emoji == "👍"))
      assert thumbs.count == 2
    end

    test "different users can react with different emojis", %{
      user: user,
      other_user: other_user,
      message: message
    } do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, other_user.id, "❤️")

      result = Chat.list_reactions([message.id])
      reactions = result[message.id]
      assert length(reactions) == 2
    end
  end

  describe "list_reactions/1" do
    test "returns grouped reactions by message_id", %{
      user: user,
      other_user: other_user,
      message: message
    } do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, other_user.id, "👍")

      result = Chat.list_reactions([message.id])

      assert Map.has_key?(result, message.id)
      reactions = result[message.id]

      thumbs = Enum.find(reactions, &(&1.emoji == "👍"))
      assert thumbs.count == 2
      assert Enum.sort(thumbs.user_ids) == Enum.sort([user.id, other_user.id])
    end

    test "returns empty map for no reactions" do
      assert Chat.list_reactions([]) == %{}
    end

    test "returns empty map for messages with no reactions", %{message: message} do
      result = Chat.list_reactions([message.id])
      assert result == %{}
    end
  end
end
