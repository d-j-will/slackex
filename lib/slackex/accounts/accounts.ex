defmodule Slackex.Accounts do
  @moduledoc """
  The Accounts context. Manages user registration, authentication,
  and session/JWT token lifecycle.
  """

  use Boundary,
    deps: [Slackex.Encrypted],
    exports: [User, UserToken, Auth, Guardian]

  import Ecto.Query

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
  Searches users by trigram similarity on username and display_name.
  Returns an empty list for queries shorter than 2 characters.

  ## Options

    * `:exclude` - list of user IDs to exclude from results
    * `:limit` - maximum number of results (default 10)
  """
  def search_users(query, opts \\ [])

  def search_users(query, _opts) when byte_size(query) < 2, do: []

  def search_users(query, opts) do
    exclude_ids = Keyword.get(opts, :exclude, []) |> List.wrap()
    limit = Keyword.get(opts, :limit, 10)

    from(u in User,
      where: u.id not in ^exclude_ids,
      where: fragment("? % ? OR ? % ?", u.username, ^query, u.display_name, ^query),
      order_by: fragment("LEAST(? <-> ?, ? <-> ?)", u.username, ^query, u.display_name, ^query),
      limit: ^limit,
      select: %{
        id: u.id,
        username: u.username,
        display_name: u.display_name,
        avatar_url: u.avatar_url
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets a user by email and verifies password. Returns nil on failure.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email_hash: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a user by id. Returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a user by id. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Updates a user's profile (display_name and status).
  Returns {:ok, user} or {:error, changeset}.
  """
  def update_user_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

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
