defmodule SlackexWeb.UserSocket do
  @moduledoc """
  WebSocket transport for authenticated mobile clients.
  Verifies JWT on connect and routes to chat and DM channels.
  """

  use Phoenix.Socket

  alias Slackex.Accounts.Auth
  alias Slackex.Notifications.OnlineTracker

  channel "chat:*", SlackexWeb.ChatChannel
  channel "dm:*", SlackexWeb.DMChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Auth.verify_api_token(token) do
      {:ok, user_id} ->
        OnlineTracker.mark_online(user_id)
        {:ok, assign(socket, :current_user_id, user_id)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"
end
