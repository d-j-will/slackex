defmodule Slackex.Messaging do
  @moduledoc """
  Messaging context facade.

  Routes real-time messages through `ChannelServer` processes with async
  persistence, in-memory caching, and PubSub broadcasting.

  Use this module as the entry point for all send/receive operations from
  LiveViews, channels, and API controllers.
  """

  alias Slackex.Chat
  alias Slackex.Messaging.ChannelServer
  alias Slackex.Messaging.ChannelSupervisor
  alias Slackex.Messaging.Envelope

  @pubsub Slackex.PubSub

  @doc "Sends a message to a channel. Returns `{:ok, message_map}` or `{:error, reason}`."
  @spec send_message(integer(), integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def send_message(channel_id, sender_id, content, _opts \\ []) do
    with {:ok, _pid} <- ChannelSupervisor.ensure_started({:channel, channel_id}) do
      ChannelServer.send_message(
        ChannelServer.via_tuple(:channel, channel_id),
        sender_id,
        content
      )
    end
  end

  @doc """
  Sends a direct message. Validates the sender is a participant before routing.
  Returns `{:ok, message_map}` or `{:error, reason}`.
  """
  @spec send_dm(integer(), integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def send_dm(dm_id, sender_id, content, _opts \\ []) do
    with {:ok, dm} <- Chat.get_dm(dm_id),
         :ok <- validate_dm_participant(dm, sender_id),
         {:ok, _pid} <- ChannelSupervisor.ensure_started({:dm, dm_id}) do
      ChannelServer.send_message(
        ChannelServer.via_tuple(:dm, dm_id),
        sender_id,
        content
      )
    end
  end

  @doc """
  Returns recent messages for a channel.

  Uses the in-memory `ChannelServer` queue if the server is running;
  falls back to a database query via `Chat.list_messages/2`.
  """
  @spec get_recent_messages(integer(), pos_integer()) :: [map()] | [struct()]
  def get_recent_messages(channel_id, limit \\ 50) do
    case Horde.Registry.lookup(Slackex.Messaging.ChannelRegistry, {:channel, channel_id}) do
      [{pid, _}] ->
        ChannelServer.get_recent_messages(pid, limit)

      [] ->
        Chat.list_messages(channel_id, limit: limit)
    end
  end

  @doc "Subscribes the calling process to channel messages."
  @spec subscribe_channel(integer()) :: :ok | {:error, term()}
  def subscribe_channel(channel_id) do
    Phoenix.PubSub.subscribe(@pubsub, "channel:#{channel_id}")
  end

  @doc "Unsubscribes the calling process from channel messages."
  @spec unsubscribe_channel(integer()) :: :ok
  def unsubscribe_channel(channel_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, "channel:#{channel_id}")
  end

  @doc "Subscribes the calling process to DM messages."
  @spec subscribe_dm(integer()) :: :ok | {:error, term()}
  def subscribe_dm(dm_id) do
    Phoenix.PubSub.subscribe(@pubsub, "dm:#{dm_id}")
  end

  @doc "Subscribes the calling process to user-level notifications."
  @spec subscribe_user(integer()) :: :ok | {:error, term()}
  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, "user:#{user_id}")
  end

  @doc "Broadcasts a typing indicator to channel subscribers."
  @spec broadcast_typing(integer(), map()) :: :ok | {:error, term()}
  def broadcast_typing(channel_id, user) do
    envelope =
      Envelope.wrap("typing", {:channel, channel_id}, %{
        user_id: user.id,
        username: user.username
      })

    Phoenix.PubSub.broadcast(@pubsub, "channel:#{channel_id}", {:envelope, envelope})
  end

  @doc "Returns the count of active ChannelServer processes."
  @spec channel_count() :: non_neg_integer()
  def channel_count do
    Horde.Registry.count(Slackex.Messaging.ChannelRegistry)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_dm_participant(dm, sender_id) do
    if sender_id == dm.user_a_id or sender_id == dm.user_b_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end
end
