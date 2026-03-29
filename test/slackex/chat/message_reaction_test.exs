defmodule Slackex.Chat.MessageReactionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.MessageReaction

  import Slackex.TestFactory

  describe "changeset/2" do
    test "valid with all required fields" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      changeset =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: message.id,
          user_id: user.id,
          emoji: "👍"
        })

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = MessageReaction.changeset(%MessageReaction{}, %{})
      refute changeset.valid?
      assert errors_on(changeset) |> Map.has_key?(:message_id)
      assert errors_on(changeset) |> Map.has_key?(:user_id)
      assert errors_on(changeset) |> Map.has_key?(:emoji)
    end

    test "enforces unique constraint on message_id + user_id + emoji" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      insert(:message_reaction, message: message, user: user, emoji: "👍")

      {:error, changeset} =
        %MessageReaction{}
        |> MessageReaction.changeset(%{message_id: message.id, user_id: user.id, emoji: "👍"})
        |> Repo.insert()

      assert errors_on(changeset) |> Map.has_key?(:message_id)
    end

    test "same user can react with different emojis" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      insert(:message_reaction, message: message, user: user, emoji: "👍")

      {:ok, _} =
        %MessageReaction{}
        |> MessageReaction.changeset(%{message_id: message.id, user_id: user.id, emoji: "❤️"})
        |> Repo.insert()
    end
  end
end
