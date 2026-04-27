defmodule Slackex.Notifications.PushAdapter.Stub do
  @moduledoc """
  No-op push adapter for development and tests. Logs each delivery and,
  when running under test (Process.get(:push_test_pid) is set), forwards
  the call to that pid as `{:stub_push_sent, token, payload}` so tests
  can assert delivery without standing up real APNs/FCM/VAPID infrastructure.
  """

  require Logger

  @spec send_push(String.t(), String.t(), map()) :: :ok
  def send_push(token, platform, payload) do
    Logger.info(
      "[PushAdapter.Stub] #{platform} → #{String.slice(token, 0, 40)}: #{payload["title"]} — #{payload["body"]}"
    )

    case Process.get(:push_test_pid) do
      pid when is_pid(pid) -> send(pid, {:stub_push_sent, token, payload})
      _ -> :noop
    end

    :ok
  end
end
