defmodule Slackex.Pipeline do
  @moduledoc false
  use Boundary,
    deps: [Slackex.Chat, Slackex.Infrastructure],
    exports: [BatchWriter]
end
