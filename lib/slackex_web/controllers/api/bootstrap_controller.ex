defmodule SlackexWeb.API.BootstrapController do
  @moduledoc """
  Returns initial app state for authenticated clients: user, channels, DMs, unread counts.
  """

  use SlackexWeb, :controller

  alias Slackex.Chat

  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    channels = Chat.list_user_channels(user.id)
    dms = Chat.list_dms(user.id)

    unread_counts =
      Map.new(channels, fn channel ->
        {to_string(channel.id), Chat.unread_count(user.id, channel.id)}
      end)

    render(conn, :index,
      user: user,
      channels: channels,
      dms: dms,
      unread_counts: unread_counts
    )
  end
end
