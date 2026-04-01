defmodule Slackex.Analytics.PruneWorker do
  @moduledoc "Oban cron job that prunes analytics events older than the configured retention period."

  use Oban.Worker, queue: :analytics, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Slackex.Analytics.Event
  alias Slackex.Repo

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days =
      Application.get_env(:slackex, Slackex.Analytics)[:retention_days] || @default_retention_days

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-retention_days * 86_400, :second)
      |> DateTime.truncate(:microsecond)

    {deleted, _} =
      Event
      |> where([e], e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info("Analytics: pruned #{deleted} events older than #{retention_days} days")
    end

    :ok
  end
end
