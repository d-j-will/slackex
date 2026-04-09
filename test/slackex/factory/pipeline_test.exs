defmodule Slackex.Factory.PipelineTest do
  @moduledoc """
  Integration tests verifying the full factory pipeline traversal and
  PubSub wiring. Covers DISTILL criteria WS-1 (walking skeleton) and
  IC-1 (PubSub broadcast on every state transition).
  """

  use Slackex.DataCase, async: false

  alias Slackex.Factory

  setup do
    Phoenix.PubSub.subscribe(Slackex.PubSub, "factory:events")
    bot = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    insert(:subscription, user: bot, channel: channel)
    FunWithFlags.enable(:dark_factory)
    %{bot: bot, channel: channel}
  end

  describe "full pipeline traversal (WS-1)" do
    test "queue -> claim -> heartbeat -> submit -> verify -> completed", %{
      bot: bot,
      channel: channel
    } do
      # Queue
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/test/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert run.status == "queued"
      assert_receive {:factory_run_updated, _}, 1000

      # Claim
      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc123"})
      assert run.status == "implementing"
      assert_receive {:factory_run_updated, _}, 1000

      # Heartbeat
      {:ok, _} = Factory.heartbeat(run.id, run.claim_token, "Working on it")
      assert_receive {:factory_run_updated, _}, 1000

      # Submit success
      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{tests: 42, failures: 0}
        })

      assert run.status == "awaiting_verification"
      assert_receive {:factory_run_updated, _}, 1000

      # Claim verification
      {:ok, run} = Factory.claim_verification(run.id)
      assert run.status == "verifying_tier2"
      assert_receive {:factory_run_updated, _}, 1000

      # Submit verification pass
      {:ok, run} =
        Factory.submit_verification(run.id, %{
          claim_token: run.claim_token,
          passed: true,
          scenarios_run: 5,
          scenarios_passed: 5,
          details: %{}
        })

      assert run.status == "completed"
      assert run.tier2_result.scenarios_run == 5
      assert_receive {:factory_run_updated, _}, 1000
    end
  end

  describe "failure paths" do
    test "failure with retries remaining stays implementing", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/retry/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      # Drain queue and claim PubSub messages
      assert_receive {:factory_run_updated, _}, 1000
      assert_receive {:factory_run_updated, _}, 1000

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: false,
          summary: %{error: "test failures"}
        })

      assert run.status == "implementing"
      assert run.attempt == 2
      assert_receive {:factory_run_updated, _}, 1000
    end

    test "failure exhausted transitions to needs_review", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/exhausted/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          max_attempts: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      # Drain queue and claim PubSub messages
      assert_receive {:factory_run_updated, _}, 1000
      assert_receive {:factory_run_updated, _}, 1000

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: false,
          summary: %{error: "test failures"}
        })

      assert run.status == "needs_review"
      assert_receive {:factory_run_updated, _}, 1000
    end
  end

  describe "PubSub wiring (IC-1)" do
    test "queue_run broadcasts {:factory_run_updated, run}", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/pubsub-queue/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert_receive {:factory_run_updated, %{id: id}}, 1000
      assert id == run.id
    end

    test "claim_run broadcasts with implementing status", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/pubsub-claim/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert_receive {:factory_run_updated, _}, 1000

      {:ok, claimed} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert_receive {:factory_run_updated, %{id: id, status: "implementing"}}, 1000
      assert id == claimed.id
    end

    test "submit_result broadcasts on success", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/pubsub-submit/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      # Drain queue and claim broadcasts
      assert_receive {:factory_run_updated, _}, 1000
      assert_receive {:factory_run_updated, _}, 1000

      {:ok, _} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{tests: 10}
        })

      assert_receive {:factory_run_updated, %{status: "awaiting_verification"}}, 1000
    end

    test "cancel_run broadcasts with cancelled status", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/pubsub-cancel/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert_receive {:factory_run_updated, _}, 1000

      {:ok, _} = Factory.cancel_run(run.id, %{bot_user_id: bot.id})

      assert_receive {:factory_run_updated, %{status: "cancelled"}}, 1000
    end
  end
end
