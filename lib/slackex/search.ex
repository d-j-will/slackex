defmodule Slackex.Search do
  @moduledoc false
  use Boundary,
    deps: [Slackex.Cache, Slackex.Chat, Slackex.Embeddings],
    exports: [HistoryLoader, MessageSearch, RAGContext]

  alias Slackex.Search.MessageSearch

  @doc """
  Searches messages accessible to the given user.

  Dispatches to the appropriate search mode based on `:mode` option:

    * `:text` - full-text search only (no embedding generation)
    * `:semantic` - semantic similarity search only
    * `:hybrid` (default) - runs FTS and semantic in parallel, merges with RRF

  Returns `{:ok, [Message.t()]}` or `{:error, reason}`.

  ## Options

    * `:mode` - search mode, one of `:text`, `:semantic`, `:hybrid` (default `:hybrid`)
    * `:limit` - maximum results (default 20)
    * `:offset` - pagination offset (default 0)
    * `:channel_id` - scope search to a specific channel
    * `:threshold` - minimum similarity for semantic/hybrid (default 0.3)
    * `:embedding_client` - embedding generation function for DI

  """
  @spec search_messages(integer(), String.t(), keyword()) ::
          {:ok, [Ecto.Schema.t()]} | {:error, term()}
  def search_messages(user_id, query, opts \\ []) do
    if FunWithFlags.enabled?(:message_search) do
      {mode, search_opts} = Keyword.pop(opts, :mode, :hybrid)

      case mode do
        :text -> MessageSearch.text_search(user_id, query, search_opts)
        :semantic -> MessageSearch.semantic_search(user_id, query, search_opts)
        :hybrid -> MessageSearch.hybrid_search(user_id, query, search_opts)
      end
    else
      {:error, :feature_disabled}
    end
  end
end
