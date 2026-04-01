defmodule Slackex.Analytics.TrackWorker do
  @moduledoc """
  Oban worker that persists an analytics event to the database.

  Receives pre-validated event attributes from `Slackex.Analytics.track/3`
  and inserts an `Analytics.Event` record. Returns `{:error, changeset}` on
  validation failure so Oban retries up to `max_attempts` times.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  alias Slackex.Analytics.Event
  alias Slackex.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    attrs = %{
      event_type: args["event_type"],
      event_category: args["event_category"],
      event_name: args["event_name"],
      user_id: args["user_id"],
      session_id: args["session_id"],
      metadata: args["metadata"] || %{}
    }

    case Event.changeset(%Event{}, attrs) |> Repo.insert() do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
