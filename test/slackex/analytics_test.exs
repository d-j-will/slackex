defmodule Slackex.AnalyticsTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.Event

  describe "Event.changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{
        event_type: "page_view",
        event_category: "product",
        event_name: "chat_index_viewed",
        session_id: "test-session-123",
        metadata: %{"path" => "/chat/general"}
      }

      changeset = Event.changeset(%Event{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :id) != nil
      assert get_change(changeset, :inserted_at) != nil
    end

    test "rejects invalid event_type" do
      attrs = %{event_type: "invalid", event_category: "product", event_name: "test"}
      changeset = Event.changeset(%Event{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_type]
    end

    test "rejects invalid event_category" do
      attrs = %{event_type: "page_view", event_category: "invalid", event_name: "test"}
      changeset = Event.changeset(%Event{}, attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_category]
    end

    test "requires event_type, event_category, event_name" do
      changeset = Event.changeset(%Event{}, %{})
      refute changeset.valid?
      assert changeset.errors[:event_type]
      assert changeset.errors[:event_category]
      assert changeset.errors[:event_name]
    end
  end

  describe "track/3" do
    setup do
      FunWithFlags.enable(:website_analytics)
      :ok
    end

    test "enqueues a TrackWorker job with correct args" do
      user = insert(:user)

      Oban.Testing.with_testing_mode(:manual, fn ->
        Slackex.Analytics.track(
          %{user_id: user.id, session_id: "sess-789"},
          "feature_used",
          %{feature: "reactions", action: "add"}
        )

        assert_enqueued(
          worker: Slackex.Analytics.TrackWorker,
          args: %{
            "event_type" => "feature_used",
            "event_category" => "product",
            "event_name" => "feature_used",
            "user_id" => user.id,
            "session_id" => "sess-789",
            "metadata" => %{"feature" => "reactions", "action" => "add"}
          }
        )
      end)
    end

    test "does not enqueue when :website_analytics flag is disabled" do
      FunWithFlags.disable(:website_analytics)

      Oban.Testing.with_testing_mode(:manual, fn ->
        Slackex.Analytics.track(
          %{user_id: 1, session_id: "sess-000"},
          "page_view",
          %{path: "/chat"}
        )

        refute_enqueued(worker: Slackex.Analytics.TrackWorker)
      end)
    end

    test "does not enqueue for bot users" do
      bot = insert(:user, is_bot: true)

      Oban.Testing.with_testing_mode(:manual, fn ->
        Slackex.Analytics.track(
          %{user_id: bot.id, session_id: "sess-bot", is_bot: true},
          "page_view",
          %{path: "/chat"}
        )

        refute_enqueued(worker: Slackex.Analytics.TrackWorker)
      end)
    end

    test "does not enqueue for users with :exclude_from_analytics flag" do
      user = insert(:user)
      FunWithFlags.enable(:exclude_from_analytics, for_actor: user)

      Oban.Testing.with_testing_mode(:manual, fn ->
        Slackex.Analytics.track(
          %{user_id: user.id, session_id: "sess-admin", user: user},
          "page_view",
          %{path: "/chat"}
        )

        refute_enqueued(worker: Slackex.Analytics.TrackWorker)
      end)

      FunWithFlags.disable(:exclude_from_analytics, for_actor: user)
    end
  end

  describe "page_views/1" do
    test "returns page views grouped by path with counts" do
      user = insert(:user)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        user_id: user.id,
        metadata: %{"path" => "/chat/general"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        user_id: user.id,
        metadata: %{"path" => "/chat/general"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        user_id: user.id,
        metadata: %{"path" => "/chat/random"},
        inserted_at: now
      )

      results = Slackex.Analytics.page_views(period: :last_7_days)
      general = Enum.find(results, &(&1.path == "/chat/general"))
      assert general.count == 2
      assert general.unique_users == 1
    end

    test "excludes reconnect events by default" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat", "is_reconnect" => "true"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat", "is_reconnect" => "false"},
        inserted_at: now
      )

      results = Slackex.Analytics.page_views(period: :last_7_days)
      chat = Enum.find(results, &(&1.path == "/chat"))
      assert chat.count == 1
    end
  end

  describe "feature_usage/1" do
    test "returns feature usage grouped by feature name" do
      user1 = insert(:user)
      user2 = insert(:user)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event,
        event_type: "feature_used",
        event_name: "feature_used",
        event_category: "product",
        user_id: user1.id,
        metadata: %{"feature" => "search"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "feature_used",
        event_name: "feature_used",
        event_category: "product",
        user_id: user2.id,
        metadata: %{"feature" => "search"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "feature_used",
        event_name: "feature_used",
        event_category: "product",
        user_id: user1.id,
        metadata: %{"feature" => "reactions"},
        inserted_at: now
      )

      results = Slackex.Analytics.feature_usage(period: :last_30_days)
      search = Enum.find(results, &(&1.feature == "search"))
      assert search.count == 2
      assert search.unique_users == 2
    end
  end

  describe "errors/1" do
    test "returns errors grouped by message with counts" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event,
        event_type: "js_error",
        event_category: "error",
        event_name: "js_error",
        metadata: %{"message" => "TypeError: null"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "js_error",
        event_category: "error",
        event_name: "js_error",
        metadata: %{"message" => "TypeError: null"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "server_error",
        event_category: "error",
        event_name: "server_error",
        metadata: %{"message" => "500 error"},
        inserted_at: now
      )

      results = Slackex.Analytics.errors(period: :last_24_hours)
      type_error = Enum.find(results, &(&1.message == "TypeError: null"))
      assert type_error.count == 2

      js_only = Slackex.Analytics.errors(period: :last_24_hours, category: "js_error")
      assert length(js_only) == 1
    end
  end

  describe "slow_pages/1" do
    test "returns pages exceeding the duration threshold" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat/general", "duration_ms" => 600},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat/general", "duration_ms" => 700},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat/random", "duration_ms" => 100},
        inserted_at: now
      )

      results = Slackex.Analytics.slow_pages(threshold_ms: 500, period: :last_7_days)
      assert length(results) == 1
      assert hd(results).path == "/chat/general"
      assert hd(results).avg_duration_ms == 650.0
    end
  end

  describe "hotspots/1" do
    test "returns pages ranked by composite score" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for _ <- 1..10 do
        insert(:analytics_event,
          event_type: "page_view",
          event_name: "page_view",
          metadata: %{"path" => "/chat/general", "duration_ms" => 200},
          inserted_at: now
        )
      end

      insert(:analytics_event,
        event_type: "js_error",
        event_category: "error",
        event_name: "js_error",
        metadata: %{"url" => "/chat/general"},
        inserted_at: now
      )

      insert(:analytics_event,
        event_type: "page_view",
        event_name: "page_view",
        metadata: %{"path" => "/chat/random", "duration_ms" => 100},
        inserted_at: now
      )

      results = Slackex.Analytics.hotspots(period: :last_7_days)
      assert results != []
      assert hd(results).path == "/chat/general"
    end
  end

  describe "active_user_count/1" do
    test "returns count of distinct active users" do
      user1 = insert(:user)
      user2 = insert(:user)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert(:analytics_event, user_id: user1.id, inserted_at: now)
      insert(:analytics_event, user_id: user1.id, inserted_at: now)
      insert(:analytics_event, user_id: user2.id, inserted_at: now)

      assert Slackex.Analytics.active_user_count(period: :last_24_hours) == 2
    end
  end
end
