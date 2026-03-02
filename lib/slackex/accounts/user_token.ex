defmodule Slackex.Accounts.UserToken do
  @moduledoc """
  Schema for session and JWT token persistence with revocation support.
  """

  use Ecto.Schema
  import Ecto.Query

  @rand_size 32
  @session_validity_in_days 14

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, Slackex.Accounts.User

    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

  @doc """
  Builds a token and its hash for session storage.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(:sha256, token)
    {token, %__MODULE__{token: hashed, context: "session", user_id: user.id}}
  end

  @doc """
  Builds a changeset for storing a hashed JTI.
  """
  def build_jti_token(user, jti, context) do
    hashed = :crypto.hash(:sha256, jti)
    %__MODULE__{token: hashed, context: context, user_id: user.id}
  end

  @doc """
  Checks if a session token is valid and returns the user query.
  """
  def verify_session_token_query(token) do
    hashed = :crypto.hash(:sha256, token)

    query =
      from t in __MODULE__,
        join: user in assoc(t, :user),
        where:
          t.token == ^hashed and t.context == "session" and
            t.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  @doc """
  Query for looking up a user by session token.
  """
  def token_and_context_query(token, "session") do
    hashed = :crypto.hash(:sha256, token)
    from __MODULE__, where: [token: ^hashed, context: "session"]
  end

  def token_and_context_query(token, context) do
    from __MODULE__, where: [token: ^token, context: ^context]
  end

  @doc """
  Query for all tokens for a given user and contexts.
  """
  def user_and_contexts_query(user, :all) do
    from t in __MODULE__, where: t.user_id == ^user.id
  end

  def user_and_contexts_query(user, [_ | _] = contexts) do
    from t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
