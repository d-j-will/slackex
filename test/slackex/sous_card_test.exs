defmodule Slackex.SousCardTest do
  @moduledoc "ChannelServer-dependent Sous tests — shared sandbox, not async."
  use Slackex.DataCase, async: false

  import Ecto.Query

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{WorkItem, WorkItemEvent}

  setup do
    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        title: "Card me",
        what: "w",
        stakeholders: []
      })

    %{user: user, channel: channel, wi: wi}
  end

  test "posts a chat message and records card_message_id via a :card_posted event", %{
    wi: wi,
    user: u
  } do
    Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.cards_topic(wi.channel_id))

    assert {:ok, updated} = Sous.post_decision_card(wi, u.id)
    assert updated.card_message_id

    assert_receive {:decision_card, msg_id, %WorkItem{} = card_wi}, 2000
    assert card_wi.id == wi.id
    assert msg_id == updated.card_message_id

    events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
    assert Enum.map(events, & &1.type) == [:created, :card_posted]
  end

  test "card_messages_for_channel/1 maps card_message_id => work_item", %{
    wi: wi,
    user: u,
    channel: c
  } do
    {:ok, carded} = Sous.post_decision_card(wi, u.id)

    map = Sous.card_messages_for_channel(c.id)
    assert Map.has_key?(map, carded.card_message_id)
    assert map[carded.card_message_id].id == wi.id
  end
end
