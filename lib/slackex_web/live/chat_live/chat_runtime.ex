defmodule SlackexWeb.ChatLive.ChatRuntime do
  @moduledoc """
  Connected chat-session lifecycle for `ChatLive.Index`.

  Owns subscriptions, presence, and heartbeat scheduling so `mount/3`,
  `handle_info/2`, and `terminate/2` can stay as thin adapters.
  """

  alias Slackex.Messaging
  alias Slackex.Notifications.ActiveTracker
  alias Slackex.Notifications.OnlineTracker

  @presence_topic "presence:online"
  @profile_topic "profile:updates"
  @online_heartbeat_interval_ms 60_000
  @active_heartbeat_interval_ms 10_000

  @type plan :: %{
          channel_ids: [integer()],
          dm_ids: [integer()]
        }

  @spec start_session(integer()) :: :ok
  def start_session(user_id) do
    user_id
    |> Messaging.subscribe_user()
    |> ensure_subscription!()

    Slackex.PubSub
    |> Phoenix.PubSub.subscribe(@presence_topic)
    |> ensure_subscription!()

    Slackex.PubSub
    |> Phoenix.PubSub.subscribe(@profile_topic)
    |> ensure_subscription!()

    OnlineTracker.mark_online(user_id)
    ActiveTracker.mark_active(user_id)

    Slackex.PubSub
    |> Phoenix.PubSub.broadcast(@presence_topic, {:presence, :online, user_id})
    |> ensure_broadcast!()

    Process.send_after(self(), :online_heartbeat, @online_heartbeat_interval_ms)
    Process.send_after(self(), :active_heartbeat, @active_heartbeat_interval_ms)

    :ok
  end

  @spec start(integer(), plan()) :: :ok
  def start(user_id, runtime_plan) do
    start_session(user_id)
    sync_conversation_subscriptions(%{channel_ids: [], dm_ids: []}, runtime_plan)
    :ok
  end

  @spec sync_conversation_subscriptions(plan(), plan()) :: :ok
  def sync_conversation_subscriptions(initial_plan, final_plan) do
    initial_channel_ids = MapSet.new(initial_plan.channel_ids)
    final_channel_ids = MapSet.new(final_plan.channel_ids)
    initial_dm_ids = MapSet.new(initial_plan.dm_ids)
    final_dm_ids = MapSet.new(final_plan.dm_ids)

    final_channel_ids
    |> MapSet.difference(initial_channel_ids)
    |> Enum.each(fn channel_id ->
      channel_id
      |> Messaging.subscribe_channel()
      |> ensure_subscription!()
    end)

    initial_channel_ids
    |> MapSet.difference(final_channel_ids)
    |> Enum.each(&Messaging.unsubscribe_channel/1)

    final_dm_ids
    |> MapSet.difference(initial_dm_ids)
    |> Enum.each(fn dm_id ->
      dm_id
      |> Messaging.subscribe_dm()
      |> ensure_subscription!()
    end)

    initial_dm_ids
    |> MapSet.difference(final_dm_ids)
    |> Enum.each(&Messaging.unsubscribe_dm/1)

    :ok
  end

  @spec refresh_online(integer()) :: :ok
  def refresh_online(user_id) do
    OnlineTracker.refresh(user_id)
    Process.send_after(self(), :online_heartbeat, @online_heartbeat_interval_ms)
    :ok
  end

  @spec refresh_active(integer(), boolean()) :: :ok
  def refresh_active(user_id, page_visible) do
    if page_visible do
      ActiveTracker.mark_active(user_id)
    end

    Process.send_after(self(), :active_heartbeat, @active_heartbeat_interval_ms)
    :ok
  end

  @spec stop(integer()) :: :ok
  def stop(user_id) do
    OnlineTracker.mark_offline(user_id)
    ActiveTracker.mark_inactive(user_id)

    Slackex.PubSub
    |> Phoenix.PubSub.broadcast(@presence_topic, {:presence, :offline, user_id})
    |> ensure_broadcast!()

    :ok
  end

  defp ensure_subscription!(:ok), do: :ok
  defp ensure_subscription!({:error, {:already_registered, _pid}}), do: :ok

  defp ensure_broadcast!(:ok), do: :ok

  defp ensure_broadcast!({:error, reason}) do
    raise "chat runtime broadcast failed: #{inspect(reason)}"
  end
end
