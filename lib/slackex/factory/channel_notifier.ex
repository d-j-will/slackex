defmodule Slackex.Factory.ChannelNotifier do
  @moduledoc """
  Subscribes to factory PubSub events and posts status updates to the
  run's channel thread. Uses the bot user who queued the run as sender.

  Supervised with `restart: :temporary` — factory notifications failing
  must not affect the chat application.
  """

  use GenServer

  require Logger

  @pubsub Slackex.PubSub
  @topic "factory:events"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    _ = Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:factory_run_updated, run}, state) do
    if FunWithFlags.enabled?(:dark_factory) do
      notify(run)
    end

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp notify(%{channel_id: nil}), do: :ok

  defp notify(run) do
    events = Slackex.Factory.list_events(run.id)
    latest = List.last(events)

    if latest do
      message = format_message(run, latest)
      post_to_thread(run, message)
    end
  rescue
    error ->
      Logger.warning("ChannelNotifier failed for run #{run.id}: #{inspect(error)}")
  end

  defp format_message(run, event) do
    prefix = "[Factory: #{Path.basename(run.spec_path)}]"

    case event.event_type do
      "status_change" -> "#{prefix} #{event.message}"
      "progress" -> "#{prefix} #{event.message}"
      "error" -> "#{prefix} Error: #{event.message}"
      _ -> "#{prefix} #{event.message}"
    end
  end

  defp post_to_thread(%{thread_message_id: nil} = run, message) do
    # First message — create the thread
    case Slackex.Messaging.send_message(run.channel_id, run.queued_by_id, message, []) do
      {:ok, msg} ->
        run
        |> Ecto.Changeset.change(thread_message_id: msg.id)
        |> Slackex.Repo.update()

      {:error, reason} ->
        Logger.warning("ChannelNotifier: failed to create thread: #{inspect(reason)}")
    end
  end

  defp post_to_thread(run, message) do
    case Slackex.Messaging.send_reply(
           run.channel_id,
           :channel,
           run.queued_by_id,
           run.thread_message_id,
           message
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("ChannelNotifier: failed to post update: #{inspect(reason)}")
    end
  end
end
