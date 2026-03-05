defmodule Slackex.Embeddings.Supervisor do
  @moduledoc """
  Dedicated supervisor for the embedding serving pipeline.

  Isolates EmbeddingServing crashes from the main application supervisor.
  Uses a generous restart budget (5 restarts / 300 seconds) to tolerate
  transient EXLA/model failures without exhausting too quickly. The parent
  supervisor starts this child with `restart: :temporary` so that if this
  supervisor does die, the app keeps serving traffic — embeddings degrade
  gracefully rather than cascading a shutdown.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Slackex.Embeddings.EmbeddingServing]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 300)
  end
end
