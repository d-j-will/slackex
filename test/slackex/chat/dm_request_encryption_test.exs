defmodule Slackex.Chat.DMRequestEncryptionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.DMRequest

  describe "dm_request preview_text encryption" do
    test "creating a DM request stores preview_text as encrypted binary, not plaintext" do
      sender = insert_user_with_age_days(8)
      recipient = insert(:user)
      channel = insert(:channel, creator: sender)
      _sub1 = insert(:subscription, user: sender, channel: channel, role: "owner")
      _sub2 = insert(:subscription, user: recipient, channel: channel, role: "member")

      {:ok, request} = Chat.create_dm_request(sender.id, recipient.id, "secret preview")

      assert request.preview_text == "secret preview"

      # The raw database value in encrypted_preview_text must NOT be plaintext
      raw =
        Repo.one(
          from r in "dm_requests",
            where: r.id == ^request.id,
            select: r.encrypted_preview_text
        )

      assert is_binary(raw)
      refute raw == "secret preview"
    end

    test "reading a DM request via list_pending_requests_for_user returns decrypted preview_text" do
      sender = insert_user_with_age_days(8)
      recipient = insert(:user)
      channel = insert(:channel, creator: sender)
      _sub1 = insert(:subscription, user: sender, channel: channel, role: "owner")
      _sub2 = insert(:subscription, user: recipient, channel: channel, role: "member")

      {:ok, _request} = Chat.create_dm_request(sender.id, recipient.id, "readable preview")

      [loaded] = Chat.list_pending_requests_for_user(recipient.id)
      assert loaded.preview_text == "readable preview"
    end

    test "preview_text validation (max 500 chars) still applies before encryption" do
      sender = insert(:user)
      recipient = insert(:user)
      long_text = String.duplicate("a", 501)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          preview_text: long_text
        })

      refute changeset.valid?
      assert %{preview_text: ["should be at most 500 character(s)"]} = errors_on(changeset)
    end

    test "preview_text at exactly 500 chars is accepted with encryption" do
      sender = insert(:user)
      recipient = insert(:user)
      text_500 = String.duplicate("b", 500)

      changeset =
        DMRequest.changeset(%DMRequest{}, %{
          sender_id: sender.id,
          recipient_id: recipient.id,
          preview_text: text_500
        })

      assert changeset.valid?
    end
  end
end
