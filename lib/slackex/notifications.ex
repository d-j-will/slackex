defmodule Slackex.Notifications do
  use Boundary,
    deps: [Slackex.Chat, Slackex.Cache],
    exports: [PushWorker, OnlineTracker, DeviceToken, CatchupServer]
end
