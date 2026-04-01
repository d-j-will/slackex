defmodule Slackex.Analytics.PruneWorkerTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.Event
  alias Slackex.Analytics.PruneWorker
  alias Slackex.Repo

  test "deletes events older than 90 days" do
    old =
      DateTime.utc_now()
      |> DateTime.add(-91 * 86_400, :second)
      |> DateTime.truncate(:microsecond)

    recent = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old_event = insert(:analytics_event, inserted_at: old)
    recent_event = insert(:analytics_event, inserted_at: recent)

    assert :ok = perform_job(PruneWorker, %{})

    events = Repo.all(Event)
    event_ids = Enum.map(events, & &1.id)
    assert recent_event.id in event_ids
    refute old_event.id in event_ids
  end
end
