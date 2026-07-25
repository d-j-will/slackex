defmodule Slackex.Andon.HoldCardActionTest do
  @moduledoc """
  R2 of the display slice: a card button acts on a hold without its thread.
  The event is an ordinary lifecycle event — what makes it a button is the
  derived id, which the service pins in its own suite. A mismatch between the
  two repos would show up as a double-post, not a failure, so the exact id is
  asserted here.
  """
  use Slackex.DataCase, async: false

  alias Slackex.Andon

  setup do
    user = insert(:user, username: "card-anna")
    channel = insert(:channel, creator: user, is_private: false)
    bot = Andon.bot_user()

    {:ok, _} = Slackex.Chat.Channels.join_channel(user.id, channel.id)
    {:ok, _} = Slackex.Chat.Channels.join_channel(bot.id, channel.id)
    {:ok, _} = Andon.enable_channel(channel.id)

    FunWithFlags.enable(:andon_relay)
    Application.put_env(:slackex, :andon_service_test_pid, self())
    on_exit(fn -> Application.delete_env(:slackex, :andon_service_test_pid) end)

    %{channel: channel, user: user}
  end

  defp hold(overrides \\ %{}) do
    Map.merge(
      %{"pull_id" => "pull-7", "thread" => "4242", "epoch" => 0},
      overrides
    )
  end

  test "release posts a witness_close keyed to the pull, the round and the actor", %{
    channel: channel,
    user: user
  } do
    :ok = Andon.act_on_hold(hold(), "release", channel.id, 99, user.id)

    assert_receive {:andon_event_posted, event}, 1_000
    assert event["event"] == "witness_close"
    assert event["event_id"] == "slackex-act-pull-7-witness_close-0-#{user.id}"
    assert event["actor"] == %{"relay" => "slackex", "token" => to_string(user.id)}

    # The click has no message of its own, so the origin points at the hold's
    # thread and the status message the card is rendered under.
    assert event["origin"] == %{
             "relay" => "slackex",
             "channel" => to_string(channel.id),
             "thread" => "4242",
             "message" => "99"
           }
  end

  test "ack carries the round the viewer was looking at", %{channel: channel, user: user} do
    :ok = Andon.act_on_hold(hold(%{"epoch" => 1}), "ack", channel.id, 99, user.id)

    assert_receive {:andon_event_posted, event}, 1_000
    assert event["event"] == "ack"
    assert event["event_id"] == "slackex-act-pull-7-ack-1-#{user.id}"
  end

  test "the same click twice is the same event", %{channel: channel, user: user} do
    :ok = Andon.act_on_hold(hold(), "ack", channel.id, 99, user.id)
    assert_receive {:andon_event_posted, first}, 1_000

    :ok = Andon.act_on_hold(hold(), "ack", channel.id, 99, user.id)
    assert_receive {:andon_event_posted, second}, 1_000

    assert first["event_id"] == second["event_id"]
  end
end
