defmodule SlackexWeb.DMChannel do
  @moduledoc """
  Phoenix Channel for real-time direct message conversations.
  Clients join with a JWT-authenticated socket and send/receive messages.

  Write path routes through `Slackex.Messaging` (ChannelServer → BatchWriter).
  Incoming messages arrive via Phoenix's internal PubSub subscription to "dm:{id}"
  (ChannelServer broadcasts to the same topic) and are pushed to the connected client.
  """

  use Phoenix.Channel

  alias Slackex.Chat
  alias Slackex.Messaging
  alias SlackexWeb.API.MessageJSON

  @impl true
  def join("dm:" <> dm_id_str, _params, socket) do
    dm_id = String.to_integer(dm_id_str)
    user_id = socket.assigns.current_user_id

    case Chat.get_dm(dm_id) do
      {:ok, dm} when dm.user_a_id == user_id or dm.user_b_id == user_id ->
        messages = Chat.list_dm_messages(dm_id, limit: 50)
        serialized = Enum.map(messages, &MessageJSON.data/1)
        Phoenix.PubSub.subscribe(Slackex.PubSub, "dm:#{dm_id}")
        {:ok, %{messages: serialized}, assign(socket, :dm_id, dm_id)}

      {:ok, _dm} ->
        {:error, %{reason: "unauthorized"}}

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in("new_message", %{"content" => content}, socket) do
    dm_id = socket.assigns.dm_id
    user_id = socket.assigns.current_user_id

    case Messaging.send_dm(dm_id, user_id, content) do
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
