defmodule Slackex.Messaging do
  @moduledoc """
  Messaging context facade.

  Routes real-time messages through `ChannelServer` processes with async
  persistence, in-memory caching, and PubSub broadcasting.

  Use this module as the entry point for all send/receive operations from
  LiveViews, channels, and API controllers.
  """

  use Boundary,
    deps: [
      Slackex.Accounts,
      Slackex.Chat,
      Slackex.Cache,
      Slackex.Infrastructure,
      Slackex.Notifications,
      Slackex.Pipeline
    ],
    exports: [ChannelServer, ChannelSupervisor, Envelope]

  alias Slackex.Cache
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
  Edits a message. Delegates to `Chat.edit_message/3`, then broadcasts
  `{:envelope, %{event: "message.edited"}}` on the appropriate PubSub topic.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  @spec edit_message(integer(), integer(), String.t()) ::
          {:ok, struct()} | {:error, atom()}
  def edit_message(message_id, user_id, new_content) do
    with {:ok, message} <- Chat.edit_message(message_id, user_id, new_content) do
      target = message_target(message)
      payload = %{id: message.id, content: message.content, edited_at: message.edited_at}

      _ = broadcast_envelope("message.edited", target, payload)

      Cache.update_message(target, message.id, %{
        content: message.content,
        edited_at: message.edited_at
      })

      {:ok, message}
    end
  end

  @doc """
  Deletes a message. Delegates to `Chat.delete_message/3`, then broadcasts
  `{:envelope, %{event: "message.deleted"}}` on the appropriate PubSub topic.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  @spec delete_message(integer(), integer(), keyword()) ::
          {:ok, struct()} | {:error, atom()}
  def delete_message(message_id, user_id, opts \\ []) do
    with {:ok, message} <- Chat.delete_message(message_id, user_id, opts) do
      target = message_target(message)
      payload = %{id: message.id, deleted_at: message.deleted_at}

      _ = broadcast_envelope("message.deleted", target, payload)
      Cache.remove_message(target, message.id)

      {:ok, message}
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

  @doc "Unsubscribes the calling process from DM messages."
  @spec unsubscribe_dm(integer()) :: :ok
  def unsubscribe_dm(dm_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, "dm:#{dm_id}")
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

  defp broadcast_envelope(event, {target_type, target_id}, payload) do
    envelope = Envelope.wrap(event, {target_type, target_id}, payload)

    Phoenix.PubSub.broadcast(
      @pubsub,
      pubsub_topic(target_type, target_id),
      {:envelope, envelope}
    )
  end

  defp validate_dm_participant(dm, sender_id) do
    if sender_id == dm.user_a_id or sender_id == dm.user_b_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp message_target(message) do
    cond do
      not is_nil(message.channel_id) -> {:channel, message.channel_id}
      not is_nil(message.dm_conversation_id) -> {:dm, message.dm_conversation_id}
    end
  end

  defp pubsub_topic(:channel, id), do: "channel:#{id}"
  defp pubsub_topic(:dm, id), do: "dm:#{id}"
end
