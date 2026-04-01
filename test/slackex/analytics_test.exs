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
      on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
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
end
