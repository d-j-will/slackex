defmodule SlackexWeb.ChatLive.Conversations do
  @moduledoc """
  Conversation state management extracted from ChatLive.Index.

  Handles entering/leaving channels and DMs, loading messages,
  subscriptions, and pagination.
  """

  use Phoenix.VerifiedRoutes, endpoint: SlackexWeb.Endpoint, router: SlackexWeb.Router

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2, stream: 4, stream_insert: 4]

  alias Slackex.Chat
  alias Slackex.Chat.MessageGrouping
  alias Slackex.Links
  alias Slackex.Messaging
  alias Slackex.Notifications.Preference
  alias Slackex.Search.HistoryLoader
  alias SlackexWeb.ChatLive.Helpers

  @message_page_size 50

  def enter_channel(socket, channel, can_send, user_role, target_message_id) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    # Unsubscribe first to prevent double subscription — mount's
    # subscribe_all_conversations already subscribes to all channels for
    # unread count tracking. Without this, the LiveView receives each
    # PubSub message twice, causing the second delivery to overwrite the
    # first with incorrect grouping (grouped: true against itself).
    _ =
      if connected?(socket) do
        Messaging.unsubscribe_channel(channel.id)
        Messaging.subscribe_channel(channel.id)
      end

    messages = fetch_messages_for_entry({:channel, channel.id}, target_message_id)
    reactions = messages |> Enum.map(& &1.id) |> Chat.list_reactions()
    Chat.mark_as_read(user.id, channel.id)

    channel_notification_level =
      if FunWithFlags.enabled?(:push_notifications) do
        Preference.resolve_level(user.id, channel.id)
      else
        "all"
      end

    socket
    |> assign(:active_channel, channel)
    |> assign(:can_send, can_send)
    |> assign(:user_role, user_role)
    |> assign(:page_title, "##{channel.name}")
    |> assign(:reactions, reactions)
    |> assign(:member_count, length(Chat.Members.list_members(channel.id)))
    |> assign(:pin_count, Chat.Pins.pin_count(channel.id))
    |> assign(:channel_notification_level, channel_notification_level)
    |> Helpers.reset_unread_count(:channel_counts, channel.id)
    |> assign_conversation_state(messages)
    |> assign(:sidebar_open, true)
  end

  def enter_dm(socket, dm, target_message_id) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    _ =
      if connected?(socket) do
        Messaging.unsubscribe_dm(dm.id)
        Messaging.subscribe_dm(dm.id)
      end

    other_user = Helpers.dm_other_user(dm, user.id)
    messages = fetch_messages_for_entry({:dm, dm.id}, target_message_id)
    reactions = messages |> Enum.map(& &1.id) |> Chat.list_reactions()
    Chat.mark_dm_as_read(user.id, dm.id)

    socket
    |> assign(:active_dm, dm)
    |> assign(:active_channel, nil)
    |> assign(:can_send, true)
    |> assign(:page_title, other_user.display_name || other_user.username)
    |> assign(:reactions, reactions)
    |> Helpers.reset_unread_count(:dm_counts, dm.id)
    |> assign_conversation_state(messages)
  end

  def enter_modal(socket, page_title) do
    socket
    |> leave_conversation()
    |> assign(:page_title, page_title)
  end

  def leave_conversation(socket) do
    if connected?(socket) do
      case socket.assigns do
        %{active_channel: %{id: id}} when not is_nil(id) ->
          Messaging.unsubscribe_channel(id)

        %{active_dm: %{id: id}} when not is_nil(id) ->
          Messaging.unsubscribe_dm(id)

        _ ->
          :ok
      end
    end

    socket
    |> assign(:active_channel, nil)
    |> assign(:active_dm, nil)
  end

  def load_older_messages(socket, list_fn, conversation_id, oldest_id) do
    conversation_id
    |> list_fn.(before: oldest_id, limit: @message_page_size)
    |> Enum.reverse()
    |> prepend_older_messages(socket)
  end

  def refresh_channels_and_navigate(socket, channel) do
    channels = Chat.list_user_channels(socket.assigns.current_user.id)

    socket
    |> assign(:channels, channels)
    |> push_patch(to: ~p"/chat/#{channel.slug}")
  end

  def subscribe_all_conversations(channels, dm_conversations) do
    Enum.each(channels, fn channel -> Messaging.subscribe_channel(channel.id) end)
    Enum.each(dm_conversations, fn dm -> Messaging.subscribe_dm(dm.id) end)
  end

  # -- Private ----------------------------------------------------------------

  defp assign_conversation_state(socket, messages) do
    messages = MessageGrouping.annotate(messages)

    previews =
      messages
      |> Enum.map(& &1.id)
      |> Links.list_previews_for_messages()

    socket
    |> assign(:typing_users, MapSet.new())
    |> assign(:oldest_message_id, oldest_message_id(messages))
    |> assign(:has_more_messages, length(messages) >= @message_page_size)
    |> assign(:link_previews, previews)
    |> assign(:last_message, List.last(messages))
    |> stream(:messages, messages, reset: true)
  end

  defp prepend_older_messages([], socket) do
    {:noreply, assign(socket, :has_more_messages, false)}
  end

  defp prepend_older_messages(messages, socket) do
    messages = MessageGrouping.annotate(messages)
    new_oldest = List.first(messages).id

    socket =
      messages
      |> Enum.reverse()
      |> Enum.reduce(socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0)
      end)
      |> assign(:oldest_message_id, new_oldest)
      |> assign(:has_more_messages, length(messages) >= @message_page_size)

    {:noreply, socket}
  end

  defp fetch_messages_for_entry(target, nil) do
    {list_fn, conversation_id} =
      case target do
        {:channel, id} -> {&Chat.list_messages/2, id}
        {:dm, id} -> {&Chat.list_dm_messages/2, id}
      end

    fetch_initial_messages(list_fn, conversation_id)
  end

  defp fetch_messages_for_entry(target, target_message_id) do
    {:ok, messages} = HistoryLoader.around(target, target_message_id, limit: @message_page_size)
    messages
  end

  defp fetch_initial_messages(list_fn, conversation_id) do
    conversation_id
    |> list_fn.(limit: @message_page_size)
    |> Enum.reverse()
  end

  defp oldest_message_id([first | _]), do: first.id
  defp oldest_message_id([]), do: nil
end
