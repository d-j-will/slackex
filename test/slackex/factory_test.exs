defmodule Slackex.FactoryTest do
  use Slackex.DataCase, async: true

  alias Slackex.Factory

  setup do
    user = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    %{bot: user, channel: channel}
  end

  describe "queue_run/2" do
    test "creates a run in queued status", %{bot: bot, channel: channel} do
      assert {:ok, run} =
               Factory.queue_run(%{
                 spec_path: "docs/feature/test-feature/",
                 queued_by_id: bot.id,
                 channel_id: channel.id
               })

      assert run.status == "queued"
      assert run.spec_path == "docs/feature/test-feature/"
      assert run.queued_by_id == bot.id
      assert run.attempt == 1
      assert run.max_attempts == 3
    end

    test "creates an initial status_change event", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/test-feature/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      events = Factory.list_events(run.id)
      assert [event] = events
      assert event.event_type == "status_change"
      assert event.to_status == "queued"
    end

    test "rejects missing required fields" do
      assert {:error, _changeset} = Factory.queue_run(%{})
    end
  end

  describe "list_pending/1" do
    test "returns queued runs for a bot user", %{bot: bot, channel: channel} do
      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [run] = Factory.list_pending(bot.id)
      assert run.spec_path == "docs/feature/a/"
    end

    test "does not return runs for other users", %{bot: bot, channel: channel} do
      other_bot = insert(:user, is_bot: true)

      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: other_bot.id,
          channel_id: channel.id
        })

      assert [] = Factory.list_pending(bot.id)
    end

    test "returns max 5 runs in FIFO order", %{bot: bot, channel: channel} do
      for i <- 1..7 do
        Factory.queue_run(%{
          spec_path: "docs/feature/f#{i}/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })
      end

      runs = Factory.list_pending(bot.id)
      assert length(runs) == 5
      assert hd(runs).spec_path == "docs/feature/f1/"
    end
  end

  describe "list_runs/2" do
    test "returns all non-terminal runs by default", %{bot: bot, channel: channel} do
      {:ok, _} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [_] = Factory.list_runs(bot.id)
    end

    test "filters by status", %{bot: bot, channel: channel} do
      {:ok, _} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [_] = Factory.list_runs(bot.id, status: "queued")
      assert [] = Factory.list_runs(bot.id, status: "implementing")
    end
  end

  describe "claim_run/2" do
    test "transitions queued -> implementing", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert {:ok, claimed} =
               Factory.claim_run(run.id, %{commit_sha: "abc123"})

      assert claimed.status == "implementing"
      assert claimed.spec_commit_sha == "abc123"
      assert claimed.claim_token != nil
      assert claimed.claimed_at != nil
      assert claimed.last_heartbeat_at != nil
    end

    test "returns error when already claimed", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc123"})
      assert {:error, :already_claimed} = Factory.claim_run(run.id, %{commit_sha: "def456"})
    end

    test "appends status_change event", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc123"})
      events = Factory.list_events(run.id)
      claim_event = Enum.find(events, &(&1.from_status == "queued"))
      assert claim_event.to_status == "implementing"
    end
  end

  describe "heartbeat/2" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})
      %{run: run}
    end

    test "updates last_heartbeat_at with valid token", %{run: run} do
      old_heartbeat = run.last_heartbeat_at
      Process.sleep(10)
      assert {:ok, updated} = Factory.heartbeat(run.id, run.claim_token)
      assert DateTime.compare(updated.last_heartbeat_at, old_heartbeat) == :gt
    end

    test "rejects invalid claim token", %{run: run} do
      assert {:error, :invalid_token} = Factory.heartbeat(run.id, "wrong-token")
    end

    test "appends progress event when message provided", %{run: run} do
      {:ok, _} = Factory.heartbeat(run.id, run.claim_token, "Working on step 2")
      events = Factory.list_events(run.id)
      progress = Enum.find(events, &(&1.event_type == "progress"))
      assert progress.message == "Working on step 2"
    end
  end

  describe "submit_result/2" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})
      %{run: run}
    end

    test "success transitions to awaiting_verification", %{run: run} do
      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: true,
                 branch_name: "factory/run-1",
                 summary: %{tests: 42, failures: 0}
               })

      assert updated.status == "awaiting_verification"
      assert updated.branch_name == "factory/run-1"
      assert updated.tier1_result == %{tests: 42, failures: 0}
    end

    test "failure with attempts remaining stays implementing", %{run: run} do
      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: false,
                 summary: %{error: "test failures"}
               })

      assert updated.status == "implementing"
      assert updated.attempt == 2
    end

    test "failure with no attempts remaining transitions to needs_review", %{
      bot: bot,
      channel: channel
    } do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/b/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          max_attempts: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: false,
                 summary: %{error: "test failures"}
               })

      assert updated.status == "needs_review"
    end

    test "rejects invalid claim token", %{run: run} do
      assert {:error, :invalid_token} =
               Factory.submit_result(run.id, %{
                 claim_token: "wrong",
                 success: true,
                 branch_name: "factory/run-1",
                 summary: %{}
               })
    end
  end

  describe "cancel_run/2" do
    test "cancels by claim token", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {:ok, cancelled} =
               Factory.cancel_run(run.id, %{claim_token: run.claim_token})

      assert cancelled.status == "cancelled"
    end

    test "cancels by owner (no claim token needed)", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert {:ok, cancelled} =
               Factory.cancel_run(run.id, %{bot_user_id: bot.id})

      assert cancelled.status == "cancelled"
    end

    test "rejects cancel on terminal state", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.cancel_run(run.id, %{bot_user_id: bot.id})

      assert {:error, :already_terminal} =
               Factory.cancel_run(run.id, %{bot_user_id: bot.id})
    end
  end
end
