defmodule SlackexWeb.API.MessageJSON do
  @moduledoc """
  Serializes Message structs to JSON-safe maps.
  Message IDs are Snowflake 64-bit integers serialized as strings for JavaScript safety.
  """

  alias SlackexWeb.API.UserJSON

  def data(%{
        id: id,
        content: content,
        sender: sender,
        channel_id: channel_id,
        dm_conversation_id: dm_conversation_id,
        inserted_at: inserted_at
      }) do
    %{
      id: to_string(id),
      content: content,
      sender: serialize_sender(sender),
      channel_id: if(channel_id, do: to_string(channel_id), else: nil),
      dm_conversation_id: if(dm_conversation_id, do: to_string(dm_conversation_id), else: nil),
      inserted_at: inserted_at
    }
  end

  def show(%{message: message}), do: data(message)

  defp serialize_sender(nil), do: nil
  defp serialize_sender(sender), do: UserJSON.data(sender)
end
