defmodule Slackex.Search do
  @moduledoc false
  use Boundary, deps: [Slackex.Cache, Slackex.Chat], exports: [HistoryLoader]
end
