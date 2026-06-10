defmodule Slackex.Sous.SliceAIntegrationTest do
  @moduledoc "Full chat → work-item → board spine, real facade, no faked upstream."
  use SlackexWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Slackex.Sous
  alias Slackex.Sous.WorkItem

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)

    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "/decide flows to a chat card AND the In Service board, then a move propagates", ctx do
    %{conn: conn, alice: alice, channel: channel} = ctx

    # Subscribe before posting so we don't miss the persistence confirmation.
    Phoenix.PubSub.subscribe(Slackex.PubSub, "pipeline:events")

    # A board client is live and subscribed (the consumer end of the bridge).
    {:ok, board, _html} = live(conn, ~p"/in-service")

    # Producer: open a decision + post its card through the real facade.
    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: alice.id,
        title: "Wire it up",
        what: "do the thing",
        stakeholders: [alice.id]
      })

    {:ok, carded} = Sous.post_decision_card(wi, alice.id)

    # The work item is real, with both events in order.
    assert carded.card_message_id

    events =
      Slackex.Repo.all(
        from(e in Slackex.Sous.WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      )

    assert Enum.map(events, & &1.type) == [:created, :card_posted]

    # Wait for the ChannelServer batch flush to confirm the card message is in the DB.
    # ChannelServer buffers writes and flushes every ~2s; this assert_receive proves
    # the message is persisted before the chat LiveView mounts and queries list_messages.
    assert_receive {:messages_persisted, ids}, 5_000
    assert carded.card_message_id in ids

    # The board (consumer) shows it in Mise after the broadcast.
    assert render(board) =~ "Wire it up"

    # The chat surface renders the card (loaded from the channel card map).
    {:ok, chat, _} = live(conn, ~p"/chat/#{channel.slug}")
    assert render(chat) =~ "lives in: In Service"
    assert render(chat) =~ "do the thing"

    # A move propagates to the board.
    {:ok, _} = Sous.move(wi.id, :pass, alice.id)
    assert render(board) =~ "Wire it up"
    assert Sous.list_in_flight()[:pass] |> Enum.map(& &1.id) == [wi.id]
    refute match?(%WorkItem{state: :mise}, Slackex.Repo.get!(WorkItem, wi.id))
  end
end
