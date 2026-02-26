defmodule SlackexWeb.ChatLive.Index do
  use SlackexWeb, :live_view

  alias Slackex.Accounts
  alias Slackex.Chat
  alias Slackex.Chat.Permissions
  alias Slackex.Messaging
  alias Slackex.Messaging.Envelope
  alias Slackex.Notifications.OnlineTracker
  alias SlackexWeb.ChatLive.NewDmModal
  alias SlackexWeb.ChatLive.SidebarComponent

  import SlackexWeb.ChatComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    channels = Chat.list_user_channels(user.id)
    dm_conversations = Chat.list_user_dm_conversations(user.id)

    if connected?(socket) do
      Messaging.subscribe_user(user.id)
      OnlineTracker.mark_online(user.id)
      Process.send_after(self(), :online_heartbeat, 60_000)
    end

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:dm_conversations, dm_conversations)
     |> assign(:active_channel, nil)
     |> assign(:active_dm, nil)
     |> assign(:can_send, false)
     |> assign(:typing_users, MapSet.new())
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
     |> assign(:sidebar_open, true)
     |> assign(:oldest_message_id, nil)
     |> assign(:has_more_messages, false)
     |> stream(:messages, [])}
  end

  # ---------------------------------------------------------------------------
  # Handle params
  # ---------------------------------------------------------------------------

  @impl true
  def handle_params(%{"dm_id" => dm_id}, _uri, socket) do
    user = socket.assigns.current_user
    dm = Chat.get_dm_conversation!(dm_id)

    if user.id in [dm.user_a_id, dm.user_b_id] do
      {:noreply, enter_dm(socket, dm)}
    else
      {:noreply, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    user = socket.assigns.current_user
    channel = Chat.get_channel_by_slug!(slug)

    case authorize_channel(user.id, channel) do
      {:ok, can_send} ->
        {:noreply, enter_channel(socket, channel, can_send)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have access to that channel.")
         |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new_dm}} = socket) do
    socket = leave_conversation(socket)

    {:noreply,
     socket
     |> assign(:active_channel, nil)
     |> assign(:active_dm, nil)
     |> assign(:page_title, "New Message")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> leave_conversation()
     |> assign(:page_title, "Chat")
     |> assign(:oldest_message_id, nil)
     |> assign(:has_more_messages, false)
     |> stream(:messages, [], reset: true)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    user = socket.assigns.current_user

    cond do
      socket.assigns.active_dm != nil ->
        send_message_to_dm(socket.assigns.active_dm, user, content, socket)

      socket.assigns.active_channel != nil and socket.assigns.can_send ->
        send_message_to_channel(socket.assigns.active_channel, user, content, socket)

      socket.assigns.active_channel != nil ->
        {:noreply, put_flash(socket, :error, "You don't have permission to send messages.")}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user

    cond do
      socket.assigns.active_dm != nil ->
        broadcast_typing(user, {:dm, socket.assigns.active_dm.id})

      socket.assigns.active_channel != nil and socket.assigns.can_send ->
        broadcast_typing(user, {:channel, socket.assigns.active_channel.id})

      true ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    oldest_id = socket.assigns.oldest_message_id

    cond do
      socket.assigns.active_dm != nil and oldest_id != nil and socket.assigns.has_more_messages ->
        load_older_messages(socket, &Chat.list_dm_messages/2, socket.assigns.active_dm.id, oldest_id)

      socket.assigns.active_channel != nil and oldest_id != nil and socket.assigns.has_more_messages ->
        load_older_messages(socket, &Chat.list_messages/2, socket.assigns.active_channel.id, oldest_id)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  # ---------------------------------------------------------------------------
  # PubSub / Info handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:envelope, %{event: "message.new", payload: message}}, socket) do
    message = enrich_message(message)

    socket =
      socket
      |> stream_insert(:messages, message)
      |> maybe_mark_as_read(message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:envelope, %{event: "typing", payload: payload}}, socket) do
    user = socket.assigns.current_user

    if payload.user_id != user.id do
      typing_users = MapSet.put(socket.assigns.typing_users, payload.username)
      Process.send_after(self(), {:clear_typing, payload.username}, 3_000)
      {:noreply, assign(socket, :typing_users, typing_users)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:clear_typing, username}, socket) do
    typing_users = MapSet.delete(socket.assigns.typing_users, username)
    {:noreply, assign(socket, :typing_users, typing_users)}
  end

  @impl true
  def handle_info(:online_heartbeat, socket) do
    OnlineTracker.refresh(socket.assigns.current_user.id)
    Process.send_after(self(), :online_heartbeat, 60_000)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:start_dm, user_id}, socket) do
    current_user = socket.assigns.current_user

    case Chat.find_or_create_dm(current_user.id, user_id) do
      {:ok, dm} ->
        dm_conversations = Chat.list_user_dm_conversations(current_user.id)

        {:noreply,
         socket
         |> assign(:dm_conversations, dm_conversations)
         |> push_patch(to: ~p"/chat/dm/#{dm.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start conversation.")}
    end
  end

  @impl true
  def handle_info({:sidebar_action, _action}, socket) do
    # Placeholder — sidebar actions (create channel, browse, new DM)
    # will be wired in Phase 5 Steps 2-3.
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:current_user] do
      OnlineTracker.mark_offline(socket.assigns.current_user.id)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_older_messages(socket, list_fn, conversation_id, oldest_id) do
    conversation_id
    |> list_fn.(before: oldest_id, limit: 50)
    |> Enum.reverse()
    |> prepend_older_messages(socket)
  end

  defp prepend_older_messages([], socket) do
    {:noreply, assign(socket, :has_more_messages, false)}
  end

  defp prepend_older_messages(messages, socket) do
    new_oldest = List.first(messages).id

    socket =
      messages
      |> Enum.reverse()
      |> Enum.reduce(socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0)
      end)
      |> assign(:oldest_message_id, new_oldest)
      |> assign(:has_more_messages, length(messages) >= 50)

    {:noreply, socket}
  end

  defp leave_conversation(socket) do
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

  defp enter_channel(socket, channel, can_send) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    if connected?(socket), do: Messaging.subscribe_channel(channel.id)

    messages = fetch_initial_messages(&Chat.list_messages/2, channel.id)
    Chat.mark_as_read(user.id, channel.id)

    socket
    |> assign(:active_channel, channel)
    |> assign(:can_send, can_send)
    |> assign(:page_title, "##{channel.name}")
    |> assign_conversation_state(messages)
    |> assign(:sidebar_open, true)
  end

  defp enter_dm(socket, dm) do
    user = socket.assigns.current_user
    socket = leave_conversation(socket)

    if connected?(socket), do: Messaging.subscribe_dm(dm.id)

    other_user = dm_other_user(dm, user.id)
    messages = fetch_initial_messages(&Chat.list_dm_messages/2, dm.id)

    socket
    |> assign(:active_dm, dm)
    |> assign(:active_channel, nil)
    |> assign(:can_send, true)
    |> assign(:page_title, other_user.display_name || other_user.username)
    |> assign_conversation_state(messages)
  end

  defp fetch_initial_messages(list_fn, conversation_id) do
    conversation_id
    |> list_fn.(limit: 50)
    |> Enum.reverse()
  end

  defp oldest_message_id([first | _]), do: first.id
  defp oldest_message_id([]), do: nil

  defp assign_conversation_state(socket, messages) do
    socket
    |> assign(:typing_users, MapSet.new())
    |> assign(:oldest_message_id, oldest_message_id(messages))
    |> assign(:has_more_messages, length(messages) >= 50)
    |> stream(:messages, messages, reset: true)
  end

  defp dm_other_user(dm, current_user_id) do
    other_id = if dm.user_a_id == current_user_id, do: dm.user_b_id, else: dm.user_a_id
    Accounts.get_user!(other_id)
  end

  defp broadcast_typing(user, {scope, id}) do
    {topic, target} =
      case scope do
        :dm -> {"dm:#{id}", {:dm, id}}
        :channel -> {"channel:#{id}", {:channel, id}}
      end

    envelope = Envelope.wrap("typing", target, %{user_id: user.id, username: user.username})
    Phoenix.PubSub.broadcast(Slackex.PubSub, topic, {:envelope, envelope})
  end

  defp send_message_to_channel(channel, user, content, socket) do
    Messaging.send_message(channel.id, user.id, content)
    |> handle_send_result(socket)
  end

  defp send_message_to_dm(dm, user, content, socket) do
    Messaging.send_dm(dm.id, user.id, content)
    |> handle_send_result(socket)
  end

  defp handle_send_result({:ok, _message}, socket) do
    {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}
  end

  defp handle_send_result({:error, :rate_limited}, socket) do
    {:noreply,
     put_flash(socket, :error, "You're sending messages too fast. Please slow down.")}
  end

  defp handle_send_result({:error, :backpressure}, socket) do
    {:noreply, put_flash(socket, :error, "Server is busy. Please try again in a moment.")}
  end

  defp handle_send_result({:error, :invalid_content}, socket) do
    {:noreply,
     put_flash(socket, :error, "Message content is invalid (must be 1-4000 characters).")}
  end

  defp handle_send_result({:error, _reason}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to send message.")}
  end

  defp authorize_channel(user_id, channel) do
    role = Chat.get_role(user_id, channel.id)

    cond do
      role != nil ->
        {:ok, Permissions.can?(role, :send_message)}

      not channel.is_private ->
        {:ok, false}

      true ->
        {:error, :unauthorized}
    end
  end

  defp enrich_message(%{sender: %{username: _}} = message), do: message

  defp enrich_message(%{sender_id: sender_id} = message) when is_integer(sender_id) do
    sender = Accounts.get_user!(sender_id)
    Map.put(message, :sender, sender)
  end

  defp enrich_message(message), do: message

  defp maybe_mark_as_read(socket, message) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user
    channel_id = Map.get(message, :channel_id)

    if channel && channel_id == channel.id do
      Chat.mark_as_read(user.id, channel.id)
    end

    socket
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full">
      <%!-- Mobile backdrop --%>
      <div
        :if={@sidebar_open}
        class="md:hidden fixed inset-0 z-30 bg-black/50"
        phx-click="toggle_sidebar"
      />

      <%!-- Sidebar --%>
      <div class={[
        "w-72 md:w-64 border-r border-base-300 flex-shrink-0",
        "fixed inset-y-0 left-0 z-40 transform transition-transform duration-200",
        "md:static md:translate-x-0",
        !@sidebar_open && "-translate-x-full"
      ]}>
        <.live_component
          module={SidebarComponent}
          id="sidebar"
          channels={@channels}
          active_channel={@active_channel}
          dm_conversations={@dm_conversations}
          active_dm={@active_dm}
          current_user={@current_user}
        />
      </div>

      <%!-- Main chat area --%>
      <div class="flex-1 flex flex-col min-w-0">
        <%= if @active_channel do %>
          <.conversation_header
            title={"##{@active_channel.name}"}
            subtitle={@active_channel.description}
          />
          <.message_stream streams={@streams} current_user_id={@current_user.id} />
          <.typing_indicator users={MapSet.to_list(@typing_users)} />

          <%= if @can_send do %>
            <.compose_area
              message_form={@message_form}
              placeholder={"Message ##{@active_channel.name}"}
            />
          <% else %>
            <div class="p-3 border-t border-base-300 bg-base-100 text-center text-sm text-base-content/50">
              Join this channel to send messages.
            </div>
          <% end %>
        <% else %>
          <%= if @active_dm do %>
            <.conversation_header title={@page_title} />
            <.message_stream streams={@streams} current_user_id={@current_user.id} />
            <.typing_indicator users={MapSet.to_list(@typing_users)} />
            <.compose_area message_form={@message_form} placeholder={"Message #{@page_title}"} />
          <% else %>
            <%!-- No conversation selected --%>
            <div class="flex-1 flex flex-col">
              <div class="px-4 py-3 border-b border-base-300 bg-base-100 md:hidden">
                <.sidebar_toggle />
              </div>
              <.empty_state
                title="Welcome to Slackex"
                subtitle="Select a channel from the sidebar to start chatting."
              />
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <.live_component
      :if={@live_action == :new_dm}
      module={NewDmModal}
      id="new-dm-modal"
      current_user={@current_user}
    />
    """
  end
end
