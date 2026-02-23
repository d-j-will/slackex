defmodule Slackex.Accounts.Auth do
  @moduledoc """
  JWT-based API authentication with token rotation, revocation, and
  refresh token family invalidation.
  """

  import Ecto.Query
  alias Slackex.Accounts.{Guardian, UserToken}
  alias Slackex.Repo

  @access_ttl {15, :minute}
  @refresh_ttl {30, :day}
  @grace_window_seconds 10

  @doc """
  Generates a JWT access token (15 min TTL) and persists hashed JTI to DB.
  """
  def generate_api_token(user) do
    {:ok, token, claims} =
      Guardian.encode_and_sign(user, %{}, token_type: "access", ttl: @access_ttl)

    jti = claims["jti"]
    Repo.insert!(UserToken.build_jti_token(user, jti, "api_access"))
    token
  end

  @doc """
  Generates a JWT refresh token (30 day TTL) and persists hashed JTI to DB.
  """
  def generate_refresh_token(user) do
    {:ok, token, claims} =
      Guardian.encode_and_sign(user, %{"typ" => "refresh"},
        token_type: "refresh",
        ttl: @refresh_ttl
      )

    jti = claims["jti"]
    Repo.insert!(UserToken.build_jti_token(user, jti, "api_refresh"))
    token
  end

  @doc """
  Decodes and verifies a JWT access token. Confirms JTI exists (not revoked) in DB.
  """
  def verify_api_token(token) do
    with {:ok, claims} <- Guardian.decode_and_verify(token),
         jti <- claims["jti"],
         hashed_jti <- :crypto.hash(:sha256, jti),
         token_record <-
           Repo.one(
             from t in UserToken,
               where: t.token == ^hashed_jti and t.context == "api_access"
           ),
         true <- not is_nil(token_record) do
      user_id = String.to_integer(claims["sub"])
      {:ok, user_id}
    else
      false -> {:error, :token_revoked}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges a refresh token for a new access + refresh token pair (rotation).

  Grace window: if the old refresh token was revoked within the last 10 seconds,
  returns the cached new pair (idempotent retry). Only after the grace window does
  a revoked token trigger family invalidation.
  """
  def refresh_api_token(refresh_token) do
    with {:ok, claims} <- Guardian.decode_and_verify(refresh_token),
         jti <- claims["jti"],
         hashed_jti <- :crypto.hash(:sha256, jti),
         token_record <-
           Repo.one(
             from t in UserToken, where: t.token == ^hashed_jti and t.context == "api_refresh"
           ) do
      token_record
      |> maybe_preload_user()
      |> handle_refresh_rotation(hashed_jti)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revokes a token. Refresh tokens are soft-revoked (revoked_at set).
  Access/session tokens are hard-deleted.
  """
  def revoke_token(token) do
    case Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        jti = claims["jti"]
        hashed_jti = :crypto.hash(:sha256, jti)
        context = if claims["typ"] == "refresh", do: "api_refresh", else: "api_access"

        if context == "api_refresh" do
          now = DateTime.utc_now()

          Repo.update_all(
            from(t in UserToken,
              where: t.token == ^hashed_jti and t.context == ^context
            ),
            set: [revoked_at: now]
          )
        else
          Repo.delete_all(
            from t in UserToken,
              where: t.token == ^hashed_jti and t.context == ^context
          )
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp maybe_preload_user(nil), do: nil
  defp maybe_preload_user(token_record), do: Repo.preload(token_record, :user)

  defp handle_refresh_rotation(nil, _hashed_jti), do: {:error, :token_revoked}

  defp handle_refresh_rotation(
         %UserToken{revoked_at: revoked_at, user: user},
         _hashed_jti
       )
       when not is_nil(revoked_at) do
    now = DateTime.utc_now()
    seconds_since_revoked = DateTime.diff(now, revoked_at, :second)

    if seconds_since_revoked <= @grace_window_seconds do
      {:error, :token_recently_rotated}
    else
      revoke_all_tokens_for_user(user)
      {:error, :token_family_invalidated}
    end
  end

  defp handle_refresh_rotation(%UserToken{revoked_at: nil, user: user}, hashed_jti) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {count, _} =
        Repo.update_all(
          from(t in UserToken,
            where: t.token == ^hashed_jti and t.context == "api_refresh" and is_nil(t.revoked_at)
          ),
          set: [revoked_at: now]
        )

      if count == 0 do
        Repo.rollback(:token_recently_rotated)
      else
        new_access_token = generate_api_token(user)
        new_refresh_token = generate_refresh_token(user)
        %{access_token: new_access_token, refresh_token: new_refresh_token}
      end
    end)
  end

  defp revoke_all_tokens_for_user(user) do
    Repo.delete_all(
      from t in UserToken,
        where: t.user_id == ^user.id and t.context in ["api_access", "api_refresh"]
    )
  end
end
