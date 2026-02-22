defmodule SlackexWeb.Plugs.ApiAuthPipeline do
  @moduledoc """
  Guardian plug pipeline for verifying Bearer tokens on API requests.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :slackex,
    module: Slackex.Accounts.Guardian,
    error_handler: SlackexWeb.Plugs.ApiAuthErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  plug SlackexWeb.Plugs.VerifyApiToken
  plug Guardian.Plug.LoadResource
end

defmodule SlackexWeb.Plugs.ApiAuthErrorHandler do
  @moduledoc """
  Returns a JSON 401 response for Guardian authentication failures.
  """

  import Plug.Conn

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    body = Jason.encode!(%{error: to_string(type)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
