defmodule SlackexWeb.Plugs.VerifyApiToken do
  @moduledoc """
  Plug that enforces JTI revocation and token-type checks on API requests.

  Must be placed after `Guardian.Plug.VerifyHeader` and
  `Guardian.Plug.EnsureAuthenticated` in the pipeline so that decoded
  claims are available.

  Rejects:
  - Tokens whose `typ` claim is not `"access"` (e.g. refresh tokens).
  - Tokens whose JTI has been revoked (deleted from `user_tokens`).
  """

  import Plug.Conn
  import Ecto.Query

  alias Slackex.Accounts.Guardian
  alias Slackex.Accounts.UserToken
  alias Slackex.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    claims = Guardian.Plug.current_claims(conn)

    with :ok <- verify_token_type(claims),
         :ok <- verify_not_revoked(claims) do
      conn
    else
      {:error, reason} ->
        body = Jason.encode!(%{error: to_string(reason)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, body)
        |> halt()
    end
  end

  defp verify_token_type(%{"typ" => "access"}), do: :ok
  defp verify_token_type(_), do: {:error, :invalid_token_type}

  defp verify_not_revoked(%{"jti" => jti}) do
    hashed_jti = :crypto.hash(:sha256, jti)

    case Repo.one(
           from(t in UserToken,
             where: t.token == ^hashed_jti and t.context == "api_access"
           )
         ) do
      nil -> {:error, :token_revoked}
      _record -> :ok
    end
  end

  defp verify_not_revoked(_), do: {:error, :missing_jti}
end
