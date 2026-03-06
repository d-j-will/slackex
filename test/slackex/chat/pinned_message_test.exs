defmodule Slackex.Chat.PinnedMessageTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.PinnedMessage

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = PinnedMessage.changeset(%PinnedMessage{}, %{message_id: 1, channel_id: 1})
      assert changeset.valid?
    end

    test "valid with all fields" do
      changeset =
        PinnedMessage.changeset(%PinnedMessage{}, %{
          message_id: 1,
          channel_id: 1,
          pinned_by_id: 1
        })

      assert changeset.valid?
    end

    test "invalid without message_id" do
      changeset = PinnedMessage.changeset(%PinnedMessage{}, %{channel_id: 1})
      refute changeset.valid?
      assert errors_on(changeset)[:message_id]
    end

    test "invalid without channel_id" do
      changeset = PinnedMessage.changeset(%PinnedMessage{}, %{message_id: 1})
      refute changeset.valid?
      assert errors_on(changeset)[:channel_id]
    end
  end
end
