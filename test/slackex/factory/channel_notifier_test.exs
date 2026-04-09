defmodule Slackex.Factory.ChannelNotifierTest do
  @moduledoc """
  Integration tests verifying that ChannelNotifier posts messages to
  the run's channel when factory events occur. Covers DISTILL criteria
  IC-2 (channel notification wiring) and IC-4 (feature flag guards).
  """

  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Factory

  setup do
    # Drain the ChannelNotifier's mailbox to prevent stale events from
    # previous test modules (FactoryTest is async: true and broadcasts
    # PubSub events that the long-lived ChannelNotifier picks up).
    if pid = Process.whereis(Slackex.Factory.ChannelNotifier) do
      :sys.get_state(pid, 5000)
    end

    bot = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    insert(:subscription, user: bot, channel: channel)
    FunWithFlags.enable(:dark_factory)
    %{bot: bot, channel: channel}
  end

  describe "ChannelNotifier wiring (IC-2)" do
    @tag capture_log: false
    test "queue_run triggers a message in the run's channel", %{bot: bot, channel: channel} do
      # Ensure the ChannelNotifier is alive — it has restart: :temporary,
      # so if it crashed during a previous test it won't restart automatically.
      notifier_pid = Process.whereis(Slackex.Factory.ChannelNotifier)

      notifier_pid =
        if is_nil(notifier_pid) or not Process.alive?(notifier_pid) do
          {:ok, pid} =
            Slackex.Factory.ChannelNotifier.start_link(name: Slackex.Factory.ChannelNotifier)

          pid
        else
          notifier_pid
        end

      assert Process.alive?(notifier_pid), "ChannelNotifier must be alive for this test"

      # Subscribe to the channel's PubSub topic to observe message delivery
      Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel.id}")

      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/notifier-test/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      # The ChannelNotifier receives the factory PubSub event and sends a
      # message via Messaging.send_message -> ChannelServer. The ChannelServer
      # broadcasts an envelope on the channel topic.
      assert_receive {:envelope, %{event: "message.new", payload: payload}},
                     3000,
                     "Expected ChannelNotifier to post a message to the channel"

      assert is_binary(payload.content)
      assert String.contains?(payload.content, "notifier-test")
    end
  end

  describe "feature flag guards (IC-4)" do
    test "ChannelNotifier skips posting when :dark_factory disabled", %{
      bot: bot,
      channel: channel
    } do
      FunWithFlags.disable(:dark_factory)

      # Subscribe to the channel's PubSub topic to verify no message arrives
      Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel.id}")

      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/flag-test/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      # Give ChannelNotifier time to (not) process the event
      Process.sleep(500)

      refute_receive {:envelope, %{event: "message.new", payload: _}}
    end

    test "LifecycleWorker skips when :dark_factory disabled" do
      FunWithFlags.disable(:dark_factory)
      assert :ok = perform_job(Slackex.Factory.LifecycleWorker, %{})
    end
  end
end
