defmodule Slackex.Embeddings do
  @moduledoc """
  The Embeddings context. Manages vector embeddings for semantic search
  over messages and conversations.
  """

  use Boundary,
    deps: [Slackex.Chat, Slackex.Search],
    exports: [
      MessageEmbedding,
      EmbeddingClient,
      StubClient,
      OpenAIClient,
      EmbeddingWorker,
      PersistenceListener,
      RAGContext,
      ReconciliationWorker
    ]
end
