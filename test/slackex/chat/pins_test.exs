defmodule Slackex.Chat.PinsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.Pins

  import Slackex.TestFactory

  setup do
    owner = insert(:user)
    member = insert(:user)

    {:ok, channel} =
      Chat.create_channel(owner.id, %{name: "test-pins-#{System.unique_integer([:positive])}"})

    Chat.join_channel(member.id, channel.id)
    {:ok, message} = Chat.send_message(channel.id, owner.id, "Pin this message")

    %{owner: owner, member: member, channel: channel, message: message}
  end

  describe "pin_message/3" do
    test "admin+ can pin a message", %{channel: channel, owner: owner, message: message} do
      assert {:ok, pin} = Pins.pin_message(channel.id, owner.id, message.id)
      assert pin.message_id == message.id
      assert pin.channel_id == channel.id
      assert pin.pinned_by_id == owner.id
    end

    test "regular member cannot pin", %{channel: channel, member: member, message: message} do
      assert {:error, :unauthorized} = Pins.pin_message(channel.id, member.id, message.id)
    end

    test "pinning same message twice returns error", %{
      channel: channel,
      owner: owner,
      message: message
    } do
      assert {:ok, _pin} = Pins.pin_message(channel.id, owner.id, message.id)
      assert {:error, :already_pinned} = Pins.pin_message(channel.id, owner.id, message.id)
    end
  end

  describe "unpin_message/3" do
    test "admin+ can unpin a message", %{channel: channel, owner: owner, message: message} do
      {:ok, _pin} = Pins.pin_message(channel.id, owner.id, message.id)
      assert :ok = Pins.unpin_message(channel.id, owner.id, message.id)
    end

    test "regular member cannot unpin", %{
      channel: channel,
      member: member,
      owner: owner,
      message: message
    } do
      {:ok, _pin} = Pins.pin_message(channel.id, owner.id, message.id)
      assert {:error, :unauthorized} = Pins.unpin_message(channel.id, member.id, message.id)
    end

    test "unpinning a non-pinned message returns error", %{
      channel: channel,
      owner: owner,
      message: message
    } do
      assert {:error, :not_pinned} = Pins.unpin_message(channel.id, owner.id, message.id)
    end
  end

  describe "list_pinned_messages/1" do
    test "returns pinned messages with preloaded data", %{
      channel: channel,
      owner: owner,
      message: message
    } do
      {:ok, _pin} = Pins.pin_message(channel.id, owner.id, message.id)
      pins = Pins.list_pinned_messages(channel.id)

      assert length(pins) == 1
      pin = hd(pins)
      assert pin.message.id == message.id
      assert pin.message.sender.id == owner.id
    end

    test "returns empty list when no pins", %{channel: channel} do
      assert Pins.list_pinned_messages(channel.id) == []
    end
  end

  describe "pin_count/1" do
    test "returns count of pinned messages", %{channel: channel, owner: owner} do
      assert Pins.pin_count(channel.id) == 0

      {:ok, msg1} = Chat.send_message(channel.id, owner.id, "Pin 1")
      {:ok, msg2} = Chat.send_message(channel.id, owner.id, "Pin 2")
      Pins.pin_message(channel.id, owner.id, msg1.id)
      Pins.pin_message(channel.id, owner.id, msg2.id)

      assert Pins.pin_count(channel.id) == 2
    end
  end
end
