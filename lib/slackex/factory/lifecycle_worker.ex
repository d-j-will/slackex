defmodule Slackex.Factory.LifecycleWorker do
  @moduledoc """
  Oban cron worker that runs every 2 minutes to release stale factory run
  claims. A run is stale when its last_heartbeat_at exceeds its
  heartbeat_timeout_minutes.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FunWithFlags.enabled?(:dark_factory) do
      {released, _} = Slackex.Factory.release_stale_claims()

      if released > 0 do
        Logger.info("LifecycleWorker: released #{released} stale claim(s)")
      end
    end

    :ok
  end
end
