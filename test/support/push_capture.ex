defmodule Slackex.PushCapture do
  @moduledoc "Test push adapter that sends dispatched pushes to the registered test process."

  @registry_key :slackex_push_capture_pid

  @spec register() :: :ok
  def register do
    :persistent_term.put(@registry_key, self())
    :ok
  end

  @spec unregister() :: :ok
  def unregister do
    :persistent_term.erase(@registry_key)
    :ok
  end

  @spec send_push(String.t(), String.t(), String.t(), String.t()) :: :ok
  def send_push(token, platform, title, body) do
    case :persistent_term.get(@registry_key, nil) do
      nil ->
        :ok

      pid ->
        send(pid, {:push_sent, %{token: token, platform: platform, title: title, body: body}})
    end

    :ok
  end

  @spec collect(non_neg_integer()) :: [map()]
  def collect(timeout_ms \\ 50) do
    do_collect([], timeout_ms)
  end

  defp do_collect(acc, timeout_ms) do
    receive do
      {:push_sent, push} -> do_collect([push | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
