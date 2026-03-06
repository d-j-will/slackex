defmodule Slackex.Chat.ThreadsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    user = insert(:user)
    replier = insert(:user)
    channel = insert(:channel) |> with_subscription(user) |> with_subscription(replier)
    parent = insert(:message, sender: user, channel: channel)
    %{user: user, replier: replier, channel: channel, parent: parent}
  end

  describe "send_reply/4" do
    test "creates a reply linked to parent", %{replier: replier, channel: channel, parent: parent} do
      {:ok, reply} = Chat.send_reply(channel.id, replier.id, parent.id, "A reply")

      assert reply.parent_message_id == parent.id
      assert reply.content == "A reply"
      assert reply.channel_id == channel.id
    end

    test "increments parent reply_count atomically", %{
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, _} = Chat.send_reply(channel.id, replier.id, parent.id, "Reply 1")
      {:ok, _} = Chat.send_reply(channel.id, replier.id, parent.id, "Reply 2")

      updated_parent = Chat.get_message!(parent.id)
      assert updated_parent.reply_count == 2
    end

    test "returns error for invalid parent channel", %{replier: replier} do
      other_channel = insert(:channel)
      other_msg = insert(:message, sender: replier, channel: other_channel)

      result = Chat.send_reply(other_channel.id + 999, replier.id, other_msg.id, "Bad")
      assert {:error, _} = result
    end
  end

  describe "list_thread/2" do
    test "returns replies ordered by insertion time", %{
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, r1} = Chat.send_reply(channel.id, replier.id, parent.id, "First")
      {:ok, r2} = Chat.send_reply(channel.id, replier.id, parent.id, "Second")

      replies = Chat.list_thread(parent.id)
      assert length(replies) == 2
      assert hd(replies).id == r1.id
      assert List.last(replies).id == r2.id
    end

    test "excludes soft-deleted replies", %{
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, reply} = Chat.send_reply(channel.id, replier.id, parent.id, "To delete")
      {:ok, _} = Chat.delete_message(reply.id, replier.id)

      replies = Chat.list_thread(parent.id)
      assert replies == []
    end

    test "returns empty list for message with no replies", %{parent: parent} do
      assert Chat.list_thread(parent.id) == []
    end
  end
end
