defmodule SlackexWeb.API.DeviceTokenController do
  @moduledoc """
  Manages device push notification tokens for the authenticated user.
  """

  use SlackexWeb, :controller

  alias Slackex.Notifications.DeviceToken
  alias Slackex.Repo

  def create(conn, %{"token" => token, "platform" => _platform} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.put(params, "user_id", user.id)

    existing = Repo.get_by(DeviceToken, token: token, user_id: user.id)
    base = existing || %DeviceToken{}

    case Repo.insert_or_update(DeviceToken.changeset(base, attrs)) do
      {:ok, device_token} ->
        conn
        |> put_status(:created)
        |> render(:data, device_token: device_token)

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_params"})
  end

  def delete(conn, %{"token" => token}) do
    user = Guardian.Plug.current_resource(conn)

    case Repo.get_by(DeviceToken, token: token, user_id: user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      device_token ->
        Repo.delete!(device_token)
        send_resp(conn, :no_content, "")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_params"})
  end
end
