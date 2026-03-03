defmodule Slackex.Search do
  @moduledoc false
  use Boundary,
    deps: [Slackex.Cache, Slackex.Chat, Slackex.Embeddings],
    exports: [HistoryLoader, MessageSearch]
end
