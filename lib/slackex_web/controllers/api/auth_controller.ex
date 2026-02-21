defmodule SlackexWeb.API.AuthController do
  @moduledoc """
  Handles API authentication: login and token refresh.
  """

  use SlackexWeb, :controller

  alias Slackex.Accounts
  alias Slackex.Accounts.Auth

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_credentials"})

      user ->
        access_token = Auth.generate_api_token(user)
        refresh_token = Auth.generate_refresh_token(user)

        conn
        |> put_status(:ok)
        |> render(:login,
          access_token: access_token,
          refresh_token: refresh_token,
          user: user
        )
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Auth.refresh_api_token(refresh_token) do
      {:ok, %{access_token: access_token, refresh_token: new_refresh_token}} ->
        conn
        |> put_status(:ok)
        |> render(:tokens, access_token: access_token, refresh_token: new_refresh_token)

      {:error, :token_recently_rotated} ->
        conn
        |> put_status(:ok)
        |> json(%{error: "token_recently_rotated"})

      {:error, reason} when is_atom(reason) or is_binary(reason) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: to_string(reason)})

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})
    end
  end
end
