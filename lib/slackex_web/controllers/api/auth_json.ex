defmodule SlackexWeb.API.AuthJSON do
  @moduledoc """
  Serializes auth responses (tokens and user) to JSON-safe maps.
  """

  alias SlackexWeb.API.UserJSON

  def login(%{access_token: access_token, refresh_token: refresh_token, user: user}) do
    %{
      access_token: access_token,
      refresh_token: refresh_token,
      user: UserJSON.data(user)
    }
  end

  def tokens(%{access_token: access_token, refresh_token: refresh_token}) do
    %{
      access_token: access_token,
      refresh_token: refresh_token
    }
  end
end
