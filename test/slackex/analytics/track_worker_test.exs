defmodule Slackex.Analytics.TrackWorkerTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.Event
  alias Slackex.Analytics.TrackWorker
  alias Slackex.Repo

  describe "perform/1" do
    test "inserts an analytics event into the database" do
      args = %{
        "event_type" => "page_view",
        "event_category" => "product",
        "event_name" => "chat_viewed",
        "session_id" => "sess-123",
        "metadata" => %{"path" => "/chat/general"}
      }

      assert :ok = perform_job(TrackWorker, args)
      event = Repo.one!(Event)
      assert event.event_type == "page_view"
      assert event.event_category == "product"
      assert event.event_name == "chat_viewed"
      assert event.session_id == "sess-123"
      assert event.metadata["path"] == "/chat/general"
    end

    test "inserts event with user_id when provided" do
      user = insert(:user)

      args = %{
        "event_type" => "feature_used",
        "event_category" => "product",
        "event_name" => "search_opened",
        "user_id" => user.id,
        "session_id" => "sess-456",
        "metadata" => %{"feature" => "search"}
      }

      assert :ok = perform_job(TrackWorker, args)
      event = Repo.one!(Event)
      assert event.user_id == user.id
    end

    test "returns error on invalid attrs" do
      args = %{
        "event_type" => "invalid_type",
        "event_category" => "product",
        "event_name" => "test"
      }

      assert {:error, _changeset} = perform_job(TrackWorker, args)
    end
  end
end
