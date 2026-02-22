defmodule SlackexWeb.Presence do
  @moduledoc """
  Phoenix Presence for tracking online users per channel.

  Tracks presence on topics of the form `"channel_presence:{channel_id}"`
  with metadata `%{username: String.t(), joined_at: DateTime.t()}`.
  """

  use Phoenix.Presence,
    otp_app: :slackex,
    pubsub_server: Slackex.PubSub
end
