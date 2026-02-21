defmodule SlackexWeb.API.BootstrapJSON do
  @moduledoc """
  Serializes bootstrap response (current user, channels, DMs, unread counts).
  """

  alias SlackexWeb.API.{ChannelJSON, UserJSON}

  def index(%{user: user, channels: channels, dms: dms, unread_counts: unread_counts}) do
    %{
      user: UserJSON.data(user),
      channels: Enum.map(channels, &ChannelJSON.data/1),
      dms: Enum.map(dms, &dm_data/1),
      unread_counts: unread_counts
    }
  end

  defp dm_data(%{id: id, user_a_id: user_a_id, user_b_id: user_b_id, inserted_at: inserted_at}) do
    %{
      id: to_string(id),
      user_a_id: to_string(user_a_id),
      user_b_id: to_string(user_b_id),
      inserted_at: inserted_at
    }
  end
end
