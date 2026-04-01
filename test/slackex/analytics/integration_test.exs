defmodule Slackex.Analytics.IntegrationTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics
  alias Slackex.Analytics.Event
  alias Slackex.Repo

  setup do
    FunWithFlags.enable(:website_analytics)
    on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
    :ok
  end

  test "full pipeline: track → Oban job → DB row → query returns it" do
    user = insert(:user)

    # Use :manual mode so the job is enqueued but not immediately executed,
    # allowing us to drain it explicitly and assert on the drain result.
    Oban.Testing.with_testing_mode(:manual, fn ->
      # 1. Track an event — enqueues the job without running it
      Analytics.track(
        %{user_id: user.id, session_id: "integration-test-session"},
        "feature_used",
        %{feature: "search", query_type: "hybrid"}
      )

      # 2. Drain the queue (execute the job synchronously)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :analytics)
    end)

    # 3. Verify row in DB
    event = Repo.one!(Event)
    assert event.event_type == "feature_used"
    assert event.user_id == user.id
    assert event.metadata["feature"] == "search"

    # 4. Verify query function returns it
    results = Analytics.feature_usage(period: :last_24_hours)
    assert [%{feature: "search", count: 1, unique_users: 1}] = results
  end

  test "bot users are excluded from the pipeline" do
    bot = insert(:user, is_bot: true)

    Oban.Testing.with_testing_mode(:manual, fn ->
      Analytics.track(
        %{user_id: bot.id, session_id: "bot-session", is_bot: true},
        "page_view",
        %{path: "/chat"}
      )

      refute_enqueued(worker: Slackex.Analytics.TrackWorker)
    end)
  end

  test "events are excluded when flag is disabled" do
    FunWithFlags.disable(:website_analytics)

    Oban.Testing.with_testing_mode(:manual, fn ->
      Analytics.track(
        %{user_id: 1, session_id: "disabled-session"},
        "page_view",
        %{path: "/chat"}
      )

      refute_enqueued(worker: Slackex.Analytics.TrackWorker)
    end)
  end
end
