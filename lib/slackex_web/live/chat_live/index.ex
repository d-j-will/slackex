defmodule SlackexWeb.ChatLive.Index do
  use SlackexWeb, :live_view

  alias Slackex.Accounts
  alias Slackex.Chat
  alias Slackex.Messaging

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    channels = Chat.list_user_channels(user.id)

    if connected?(socket) do
      Messaging.subscribe_user(user.id)
    end

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:active_channel, nil)
     |> assign(:typing_users, MapSet.new())
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    user = socket.assigns.current_user
    channel = Chat.get_channel_by_slug!(slug)

    if connected?(socket) do
      old_channel = socket.assigns.active_channel
      if old_channel, do: Messaging.unsubscribe_channel(old_channel.id)
      Messaging.subscribe_channel(channel.id)
    end

    messages =
      channel.id
      |> Chat.list_messages(limit: 50)
      |> Enum.reverse()

    Chat.mark_as_read(user.id, channel.id)

    {:noreply,
     socket
     |> assign(:active_channel, channel)
     |> assign(:page_title, "##{channel.name}")
     |> assign(:typing_users, MapSet.new())
     |> stream(:messages, messages, reset: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      prev_channel = socket.assigns.active_channel
      if prev_channel, do: Messaging.unsubscribe_channel(prev_channel.id)
    end

    {:noreply,
     socket
     |> assign(:active_channel, nil)
     |> assign(:page_title, "Chat")
     |> stream(:messages, [], reset: true)}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user

    if is_nil(channel) do
      {:noreply, socket}
    else
      send_message_to_channel(channel, user, content, socket)
    end
  end

  defp send_message_to_channel(channel, user, content, socket) do
    case Messaging.send_message(channel.id, user.id, content) do
      {:ok, _message} ->
        {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, "You're sending messages too fast. Please slow down.")}

      {:error, :backpressure} ->
        {:noreply, put_flash(socket, :error, "Server is busy. Please try again in a moment.")}

      {:error, :invalid_content} ->
        {:noreply,
         put_flash(socket, :error, "Message content is invalid (must be 1-4000 characters).")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message.")}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "message.new", payload: message}}, socket) do
    # Enrich the message map with sender info for display
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

    # Don't show own typing indicator
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
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp message_sender_name(%{sender: %{username: username}}), do: username
  defp message_sender_name(%{sender: %{display_name: name}}) when not is_nil(name), do: name
  defp message_sender_name(_), do: "unknown"

  defp format_time(%{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    Calendar.strftime(inserted_at, "%H:%M")
  end

  defp format_time(_), do: ""

  defp typing_text(typing_users) do
    names = MapSet.to_list(typing_users)

    case names do
      [] -> nil
      [name] -> "#{name} is typing..."
      [a, b] -> "#{a} and #{b} are typing..."
      _ -> "Several people are typing..."
    end
  end

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-80px)]">
      <%!-- Sidebar --%>
      <aside class="w-64 bg-base-200 border-r border-base-300 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <h2 class="font-bold text-lg">Channels</h2>
        </div>
        <nav class="flex-1 overflow-y-auto p-2">
          <%= if @channels == [] do %>
            <p class="text-sm text-base-content/50 p-2">No channels yet.</p>
          <% else %>
            <ul class="menu menu-sm">
              <li :for={channel <- @channels}>
                <.link
                  patch={~p"/chat/#{channel.slug}"}
                  class={[
                    "rounded-lg",
                    @active_channel && @active_channel.id == channel.id && "active"
                  ]}
                >
                  <span class="text-base-content/70">#</span>
                  {channel.name}
                </.link>
              </li>
            </ul>
          <% end %>
        </nav>
      </aside>

      <%!-- Main chat area --%>
      <div class="flex-1 flex flex-col">
        <%= if @active_channel do %>
          <%!-- Channel header --%>
          <div class="p-4 border-b border-base-300 bg-base-100">
            <h2 class="font-bold text-lg">#{@active_channel.name}</h2>
            <p :if={@active_channel.description} class="text-sm text-base-content/60">
              {@active_channel.description}
            </p>
          </div>

          <%!-- Message list --%>
          <div
            id="message-list"
            phx-hook="MessageList"
            phx-update="stream"
            class="flex-1 overflow-y-auto p-4 space-y-1"
          >
            <div :for={{dom_id, message} <- @streams.messages} id={dom_id} class="chat chat-start">
              <div class="chat-header text-sm">
                {message_sender_name(message)}
                <time class="text-xs opacity-50 ml-1">{format_time(message)}</time>
              </div>
              <div class="chat-bubble chat-bubble-neutral">
                {Map.get(message, :content, "")}
              </div>
            </div>
          </div>

          <%!-- Typing indicator --%>
          <div :if={typing_text(@typing_users)} class="px-4 py-1 text-xs text-base-content/50 italic">
            {typing_text(@typing_users)}
          </div>

          <%!-- Message input --%>
          <div class="p-4 border-t border-base-300 bg-base-100">
            <.form
              for={@message_form}
              id="message-form"
              phx-submit="send_message"
              class="flex gap-2"
            >
              <input
                type="text"
                name="message[content]"
                value={@message_form[:content].value}
                placeholder={"Message ##{@active_channel.name}"}
                class="input input-bordered flex-1"
                autocomplete="off"
                phx-debounce="100"
              />
              <button type="submit" class="btn btn-primary">Send</button>
            </.form>
          </div>
        <% else %>
          <%!-- No channel selected --%>
          <div class="flex-1 flex items-center justify-center text-base-content/50">
            <div class="text-center">
              <h2 class="text-2xl font-bold mb-2">Welcome to Slackex</h2>
              <p>Select a channel from the sidebar to start chatting.</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
