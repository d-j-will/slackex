defmodule Slackex.Embeddings.Supervisor do
  @moduledoc """
  Dedicated supervisor for the embedding serving pipeline.

  Isolates EmbeddingServing crashes from the main application supervisor.
  Repeated model-loading failures exhaust this supervisor's restart budget
  (3 restarts / 60 seconds) instead of the top-level Slackex.Supervisor,
  preventing cascading shutdown of Postgres, PubSub, and the Endpoint.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Slackex.Embeddings.EmbeddingServing]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
