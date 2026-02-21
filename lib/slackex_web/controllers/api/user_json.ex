defmodule SlackexWeb.API.UserJSON do
  @moduledoc """
  Serializes User structs to JSON-safe maps, excluding sensitive fields.
  """

  def data(%{
        id: id,
        username: username,
        display_name: display_name,
        avatar_url: avatar_url,
        status: status
      }) do
    %{
      id: to_string(id),
      username: username,
      display_name: display_name,
      avatar_url: avatar_url,
      status: status
    }
  end

  def show(%{user: user}), do: data(user)
end
