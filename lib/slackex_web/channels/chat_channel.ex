defmodule SlackexWeb.ChatChannel do
  @moduledoc """
  Phoenix Channel for real-time channel messaging.
  Clients join with a JWT-authenticated socket and send/receive messages.
  """

  use Phoenix.Channel

  alias Slackex.Chat
  alias SlackexWeb.API.MessageJSON

  @impl true
  def join("chat:" <> channel_id_str, _params, socket) do
    channel_id = String.to_integer(channel_id_str)
    user_id = socket.assigns.current_user_id

    case Chat.get_role(user_id, channel_id) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      _role ->
        messages = Chat.list_messages(channel_id, limit: 50)
        Chat.mark_as_read(user_id, channel_id)
        serialized = Enum.map(messages, &MessageJSON.data/1)
        {:ok, %{messages: serialized}, assign(socket, :channel_id, channel_id)}
    end
  end

  @impl true
  def handle_in("new_message", %{"content" => content}, socket) do
    channel_id = socket.assigns.channel_id
    user_id = socket.assigns.current_user_id

    case Chat.send_message(channel_id, user_id, content) do
      {:ok, message} ->
        broadcast!(socket, "new_message", MessageJSON.data(message))
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end
end
