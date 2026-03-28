defmodule SlackexWeb.ChatLive.Summary do
  @moduledoc """
  Summarization streaming helpers extracted from ChatLive.Index.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Slackex.AI.Summarizer

  require Logger

  def stream_summary({:channel, channel_id}, since, user_id, live_view_pid) do
    stream_summary_result(Summarizer.summarize_channel(channel_id, since, user_id), live_view_pid)
  end

  def stream_summary({:dm, dm_id}, since, user_id, live_view_pid) do
    stream_summary_result(Summarizer.summarize_dm(dm_id, since, user_id), live_view_pid)
  end

  def cancel_summary_task(socket) do
    case socket.assigns[:active_summary_task] do
      %Task{pid: pid} ->
        Process.exit(pid, :kill)
        assign(socket, active_summary_task: nil)

      _ ->
        socket
    end
  end

  def time_range_to_datetime("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  def time_range_to_datetime("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  def time_range_to_datetime("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  def time_range_to_datetime(_), do: DateTime.add(DateTime.utc_now(), -1, :day)

  defp stream_summary_result(result, live_view_pid) do
    case result do
      {:ok, stream} ->
        try do
          token_count =
            Enum.reduce(stream, 0, fn chunk, count ->
              send(live_view_pid, {:summary_token, chunk})
              count + 1
            end)

          if token_count > 0 do
            send(live_view_pid, :summary_complete)
          else
            send(live_view_pid, {:summary_error, :empty_response})
          end
        rescue
          e ->
            Logger.error("Stream enumeration failed: #{inspect(e)}")
            send(live_view_pid, {:summary_error, {:stream_error, Exception.message(e)}})
        end

      {:error, reason} ->
        Logger.error("Summarization failed: #{inspect(reason)}")
        send(live_view_pid, {:summary_error, reason})
    end
  end
end
