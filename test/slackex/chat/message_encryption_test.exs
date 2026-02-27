defmodule Slackex.Chat.MessageEncryptionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "message content encryption" do
    test "new messages are stored as encrypted binary, not plaintext" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      {:ok, message} = Chat.send_message(channel.id, user.id, "secret message")

      # The returned message should have readable plaintext
      assert message.content == "secret message"

      # But the raw database value in encrypted_content must NOT be plaintext
      raw =
        Repo.one(
          from m in "messages",
            where: m.id == ^message.id,
            select: m.encrypted_content
        )

      assert is_binary(raw)
      refute raw == "secret message"
    end

    test "reading a message via list_messages returns decrypted plaintext" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      {:ok, _message} = Chat.send_message(channel.id, user.id, "readable text")

      [loaded] = Chat.list_messages(channel.id)
      assert loaded.content == "readable text"
    end

    test "sending a DM stores encrypted content and returns readable text" do
      dm = insert(:dm_conversation)

      {:ok, message} = Chat.send_dm(dm.id, dm.user_a_id, "dm secret")

      assert message.content == "dm secret"

      raw =
        Repo.one(
          from m in "messages",
            where: m.id == ^message.id,
            select: m.encrypted_content
        )

      assert is_binary(raw)
      refute raw == "dm secret"
    end

    test "content validation (min 1, max 4000 chars) still applies before encryption" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      # Empty content should fail validation
      {:error, changeset} = Chat.send_message(channel.id, user.id, "")
      assert %{content: [_]} = errors_on(changeset)

      # Content exceeding 4000 chars should fail validation
      long_content = String.duplicate("a", 4001)
      {:error, changeset} = Chat.send_message(channel.id, user.id, long_content)
      assert %{content: [_]} = errors_on(changeset)
    end
  end
end
