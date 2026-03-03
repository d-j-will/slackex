defmodule Slackex.Workers do
  @moduledoc false
  use Boundary, deps: [Slackex.Chat, Slackex.Messaging], exports: [CacheWarmer]
end
