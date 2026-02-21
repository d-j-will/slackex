defmodule Slackex.Accounts do
  @moduledoc """
  The Accounts context. Manages user registration, authentication,
  and session/JWT token lifecycle.
  """

  alias Slackex.Accounts.{User, UserToken}
  alias Slackex.Repo

  @doc """
  Registers a new user.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a user by email and verifies password. Returns nil on failure.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a user by id. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Generates a session token and persists it to the database.
  Returns the raw binary token (to be stored in session).
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user associated with a session token. Returns nil if not found or expired.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes a session token.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end
end
