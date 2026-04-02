defmodule Slackex.Notifications.PushAdapter.Stub do
  @moduledoc "No-op push adapter used in dev/test. Logs the push payload."

  require Logger

  @spec send_push(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def send_push(token, platform, payload) do
    Logger.debug(
      "[PushAdapter.Stub] #{platform} → #{String.slice(token, 0, 40)}: #{payload["title"]} — #{payload["body"]}"
    )

    :ok
  end
end
