defmodule SlackexWeb.API.ChannelJSON do
  @moduledoc """
  Serializes Channel structs to JSON-safe maps.
  """

  def data(%{
        id: id,
        name: name,
        slug: slug,
        description: description,
        is_private: is_private,
        creator_id: creator_id,
        inserted_at: inserted_at,
        updated_at: updated_at
      }) do
    %{
      id: to_string(id),
      name: name,
      slug: slug,
      description: description,
      is_private: is_private,
      creator_id: to_string(creator_id),
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  def show(%{channel: channel}), do: data(channel)
end
