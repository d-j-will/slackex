defmodule Slackex.Andon.MirrorSnapshotTest do
  @moduledoc """
  R1 of the display slice: the mirror snapshot is kept, not just rendered to
  text. The card needs the structured holds, and a viewer who joins between
  updates needs them from the row rather than from a broadcast they missed.
  """
  use Slackex.DataCase, async: false

  alias Slackex.Andon

  setup do
    user = insert(:user, username: "mirror-anna")
    channel = insert(:channel, creator: user, is_private: false)
    bot = Andon.bot_user()

    {:ok, _} = Slackex.Chat.Channels.join_channel(user.id, channel.id)
    {:ok, _} = Slackex.Chat.Channels.join_channel(bot.id, channel.id)
    {:ok, _} = Andon.enable_channel(channel.id)

    %{channel: channel}
  end

  defp snapshot(holds) do
    %{
      "command" => "update_mirror",
      "channel" => to_string(1),
      "watermark" => 1,
      "mirror" => %{"active_holds" => holds, "unbound_pulls" => [], "oldest_open" => nil}
    }
  end

  defp hold(subject) do
    %{
      "pull_id" => "p-1",
      "class" => "defect",
      "thread" => "T-1",
      "subject" => %{"adapter" => "linear", "external_id" => subject},
      "held_since" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "escalated" => false,
      "holder" => %{"relay" => "slackex", "token" => "U-1"},
      "holder_source" => "dri",
      "acked_at" => nil,
      "ack_due_at" => nil,
      "epoch" => 0,
      "actions" => []
    }
  end

  test "the snapshot lands on the row and reaches whoever is watching", %{channel: channel} do
    Phoenix.PubSub.subscribe(Slackex.PubSub, Andon.mirror_topic(channel.id))

    :ok =
      snapshot([hold("ENG-9")])
      |> Map.put("channel", to_string(channel.id))
      |> Andon.apply_command()

    assert_receive {:andon_mirror, status_message_id, mirror}, 1_000
    assert [%{"subject" => %{"external_id" => "ENG-9"}}] = mirror["active_holds"]

    # And for anyone who arrives after the fact — same shape, from the row.
    assert %{^status_message_id => %{"active_holds" => [_]}} =
             Andon.mirror_for_channel(channel.id)
  end

  test "a stale watermark changes nothing", %{channel: channel} do
    Phoenix.PubSub.subscribe(Slackex.PubSub, Andon.mirror_topic(channel.id))

    fresh = snapshot([hold("ENG-9")]) |> Map.put("channel", to_string(channel.id))
    :ok = Andon.apply_command(fresh)
    assert_receive {:andon_mirror, _, _}, 1_000

    stale =
      snapshot([hold("ENG-OLD")])
      |> Map.put("channel", to_string(channel.id))
      |> Map.put("watermark", 0)

    :ok = Andon.apply_command(stale)
    refute_receive {:andon_mirror, _, _}, 200

    assert [%{"subject" => %{"external_id" => "ENG-9"}}] =
             Andon.mirror_for_channel(channel.id)
             |> Map.values()
             |> hd()
             |> Map.get("active_holds")
  end
end
