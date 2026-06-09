defmodule Slackex.Embeddings do
  @moduledoc """
  The Embeddings context. Manages vector embeddings for semantic search
  over messages and conversations.
  """

  use Boundary,
    deps: [Slackex.Chat],
    exports: [
      MessageEmbedding,
      EmbeddingClient,
      EmbeddingServing,
      Supervisor,
      BumblebeeClient,
      StubClient,
      OpenAIClient,
      EmbeddingWorker,
      PersistenceListener,
      ReconciliationWorker
    ]
end
