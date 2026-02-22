defmodule Slackex.Notifications.PushAdapter.Stub do
  @moduledoc "No-op push adapter used in dev/test. Logs the push payload."

  require Logger

  @spec send_push(String.t(), String.t(), String.t(), String.t()) :: :ok
  def send_push(token, platform, title, body) do
    Logger.debug("[PushAdapter.Stub] #{platform} → #{token}: #{title} — #{body}")
    :ok
  end
end
