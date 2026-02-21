defmodule SlackexWeb.DMChannel do
  @moduledoc """
  Phoenix Channel for real-time direct message conversations.
  Clients join with a JWT-authenticated socket and send/receive messages.
  """

  use Phoenix.Channel

  alias Slackex.Chat
  alias SlackexWeb.API.MessageJSON

  @impl true
  def join("dm:" <> dm_id_str, _params, socket) do
    dm_id = String.to_integer(dm_id_str)
    user_id = socket.assigns.current_user_id

    case Chat.get_dm(dm_id) do
      {:ok, dm} when dm.user_a_id == user_id or dm.user_b_id == user_id ->
        messages = Chat.list_dm_messages(dm_id, limit: 50)
        serialized = Enum.map(messages, &MessageJSON.data/1)
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

    case Chat.send_dm(dm_id, user_id, content) do
      {:ok, message} ->
        broadcast!(socket, "new_message", MessageJSON.data(message))
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end
end
