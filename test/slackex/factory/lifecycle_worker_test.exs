defmodule Slackex.Factory.LifecycleWorkerTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Factory

  setup do
    bot = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    %{bot: bot, channel: channel}
  end

  describe "release_stale_claims/0" do
    test "releases implementing run past heartbeat timeout", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          heartbeat_timeout_minutes: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      # Backdate heartbeat to exceed timeout
      stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      run
      |> Ecto.Changeset.change(last_heartbeat_at: stale)
      |> Slackex.Repo.update!()

      assert {1, _} = Factory.release_stale_claims()

      updated = Slackex.Repo.get!(Slackex.Factory.Run, run.id)
      assert updated.status == "queued"
      assert updated.claim_token == nil
      assert updated.claimed_at == nil
      assert updated.branch_name == nil
      assert updated.attempt == 1
    end

    test "releases verifying_tier2 run back to awaiting_verification", %{
      bot: bot,
      channel: channel
    } do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          heartbeat_timeout_minutes: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{}
        })

      {:ok, run} = Factory.claim_verification(run.id)

      stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      run
      |> Ecto.Changeset.change(last_heartbeat_at: stale)
      |> Slackex.Repo.update!()

      assert {1, _} = Factory.release_stale_claims()

      updated = Slackex.Repo.get!(Slackex.Factory.Run, run.id)
      assert updated.status == "awaiting_verification"
      assert updated.claim_token == nil
    end

    test "does not release runs within timeout", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {0, _} = Factory.release_stale_claims()
    end
  end

  describe "perform/1" do
    test "calls release_stale_claims" do
      assert :ok = perform_job(Slackex.Factory.LifecycleWorker, %{})
    end
  end
end
