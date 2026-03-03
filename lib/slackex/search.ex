defmodule Slackex.Search do
  use Boundary, deps: [Slackex.Cache, Slackex.Chat], exports: [HistoryLoader]
end
