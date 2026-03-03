defmodule Slackex.Workers do
  use Boundary, deps: [Slackex.Chat, Slackex.Messaging], exports: [CacheWarmer]
end
