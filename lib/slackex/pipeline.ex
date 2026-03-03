defmodule Slackex.Pipeline do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Infrastructure],
    exports: [BatchWriter]
end
