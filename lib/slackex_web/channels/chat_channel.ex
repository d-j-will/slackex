defmodule SlackexWeb.ChatChannel do
  @moduledoc """
  Phoenix Channel for real-time channel messaging.
  Clients join with a JWT-authenticated socket and send/receive messages.

  Write path routes through `Slackex.Messaging` (ChannelServer → BatchWriter).
  Incoming messages arrive via PubSub subscription to "channel:{id}" and are
  pushed directly to the connected client.
  """

  use Phoenix.Channel

  alias Slackex.Chat
  alias Slackex.Messaging
  alias SlackexWeb.API.MessageJSON

  @impl true
  def join("chat:" <> channel_id_str, _params, socket) do
    case Integer.parse(channel_id_str) do
      {channel_id, ""} ->
        user_id = socket.assigns.current_user_id

        case Chat.get_role(user_id, channel_id) do
          nil ->
            {:error, %{reason: "unauthorized"}}

          _role ->
            messages = Chat.list_messages(channel_id, limit: 50)
            Chat.mark_as_read(user_id, channel_id)
            serialized = Enum.map(messages, &MessageJSON.data/1)
            Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{channel_id}")
            {:ok, %{messages: serialized}, assign(socket, :channel_id, channel_id)}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  @impl true
  def handle_in("new_message", %{"content" => content}, socket) do
    channel_id = socket.assigns.channel_id
    user_id = socket.assigns.current_user_id

    case Messaging.send_message(channel_id, user_id, content) do
      {:ok, _message} ->
        {:reply, :ok, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited", message: "Too many messages, slow down"}},
         socket}

      {:error, :backpressure} ->
        {:reply, {:error, %{reason: "backpressure", message: "Server is busy, try again"}},
         socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized", message: "You cannot send messages here"}},
         socket}

      {:error, :invalid_content} ->
        {:reply, {:error, %{reason: "invalid_content", message: "Message content is invalid"}},
         socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:envelope, %{event: "message.new", payload: message}}, socket) do
    push(socket, "message.new", serialize_message(message))
    {:noreply, socket}
  end

  def handle_info({:envelope, %{event: "typing", payload: payload}}, socket) do
    push(socket, "typing", payload)
    {:noreply, socket}
  end

  defp serialize_message(message) do
    %{
      id: to_string(message.id),
      content: message.content,
      sender_id: to_string(message.sender_id),
      inserted_at: message.inserted_at
    }
  end
end
