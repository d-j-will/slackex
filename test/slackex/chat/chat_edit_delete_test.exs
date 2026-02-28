defmodule Slackex.Chat.ChatEditDeleteTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "edit_message/3" do
    test "owner can edit their own message content and sets edited_at" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      {:ok, message} = Chat.send_message(channel.id, user.id, "original content")

      assert {:ok, edited} = Chat.edit_message(message.id, user.id, "updated content")
      assert edited.content == "updated content"
      assert edited.edited_at != nil
    end

    test "returns {:error, :unauthorized} when user is not the message sender" do
      owner = insert(:user)
      other = insert(:user)
      channel = insert(:channel, creator: owner)
      _sub1 = insert(:subscription, user: owner, channel: channel, role: "owner")
      _sub2 = insert(:subscription, user: other, channel: channel, role: "member")

      {:ok, message} = Chat.send_message(channel.id, owner.id, "owner message")

      assert {:error, :unauthorized} = Chat.edit_message(message.id, other.id, "hijacked")
    end

    test "returns {:error, :not_found} for nonexistent message_id" do
      user = insert(:user)
      assert {:error, :not_found} = Chat.edit_message(999_999_999, user.id, "new content")
    end

    test "returns {:error, :deleted} when message is already soft-deleted" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      {:ok, message} = Chat.send_message(channel.id, user.id, "to be deleted")
      {:ok, _deleted} = Chat.delete_message(message.id, user.id)

      assert {:error, :deleted} = Chat.edit_message(message.id, user.id, "too late")
    end
  end

  describe "delete_message/3" do
    test "message owner can soft-delete their own message" do
      user = insert(:user)
      channel = insert(:channel, creator: user)
      _sub = insert(:subscription, user: user, channel: channel, role: "owner")

      {:ok, message} = Chat.send_message(channel.id, user.id, "will be deleted")

      assert {:ok, deleted} = Chat.delete_message(message.id, user.id)
      assert deleted.content == nil
      assert deleted.deleted_at != nil
    end

    test "message owner can delete own message in DM" do
      dm = insert(:dm_conversation)
      {:ok, message} = Chat.send_dm(dm.id, dm.user_a_id, "dm message")

      assert {:ok, deleted} = Chat.delete_message(message.id, dm.user_a_id)
      assert deleted.content == nil
      assert deleted.deleted_at != nil
    end

    test "channel admin can delete any message in their channel" do
      admin = insert(:user)
      member = insert(:user)
      channel = insert(:channel, creator: admin)
      _admin_sub = insert(:subscription, user: admin, channel: channel, role: "admin")
      _member_sub = insert(:subscription, user: member, channel: channel, role: "member")

      {:ok, message} = Chat.send_message(channel.id, member.id, "member message")

      assert {:ok, deleted} = Chat.delete_message(message.id, admin.id)
      assert deleted.content == nil
      assert deleted.deleted_at != nil
    end

    test "channel owner can delete any message in their channel" do
      owner = insert(:user)
      member = insert(:user)
      channel = insert(:channel, creator: owner)
      _owner_sub = insert(:subscription, user: owner, channel: channel, role: "owner")
      _member_sub = insert(:subscription, user: member, channel: channel, role: "member")

      {:ok, message} = Chat.send_message(channel.id, member.id, "member message")

      assert {:ok, deleted} = Chat.delete_message(message.id, owner.id)
      assert deleted.content == nil
    end

    test "returns {:error, :unauthorized} when non-owner non-admin deletes others message in channel" do
      owner = insert(:user)
      member1 = insert(:user)
      member2 = insert(:user)
      channel = insert(:channel, creator: owner)
      _owner_sub = insert(:subscription, user: owner, channel: channel, role: "owner")
      _sub1 = insert(:subscription, user: member1, channel: channel, role: "member")
      _sub2 = insert(:subscription, user: member2, channel: channel, role: "member")

      {:ok, message} = Chat.send_message(channel.id, member1.id, "member1 message")

      assert {:error, :unauthorized} = Chat.delete_message(message.id, member2.id)
    end

    test "returns {:error, :unauthorized} when user tries to delete others DM message" do
      dm = insert(:dm_conversation)
      {:ok, message} = Chat.send_dm(dm.id, dm.user_a_id, "user a message")

      assert {:error, :unauthorized} = Chat.delete_message(message.id, dm.user_b_id)
    end

    test "returns {:error, :not_found} for nonexistent message_id" do
      user = insert(:user)
      assert {:error, :not_found} = Chat.delete_message(999_999_999, user.id)
    end
  end
end
