defmodule Slackex.Accounts.User do
  @moduledoc """
  User schema with registration, validation, and password hashing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_dm_preferences ~w(anyone shared_channels nobody)

  @derive {Jason.Encoder,
           only: [
             :id,
             :username,
             :display_name,
             :email,
             :avatar_url,
             :status,
             :dm_preference,
             :inserted_at,
             :updated_at
           ]}

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :email, Slackex.Encrypted.Binary, source: :encrypted_email
    field :email_hash, Slackex.Encrypted.HMAC
    field :hashed_password, :string
    field :password, :string, virtual: true, redact: true
    field :avatar_url, :string
    field :status, :string, default: "offline"
    field :dm_preference, :string, default: "anyone"

    has_many :subscriptions, Slackex.Chat.Subscription
    has_many :channels, through: [:subscriptions, :channel]

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for user registration. Validates all required fields,
  enforces username format, and hashes the password.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :email, :password, :avatar_url])
    |> validate_required([:username, :email, :password])
    |> validate_username()
    |> validate_email()
    |> validate_password()
    |> put_email_hash()
    |> unique_constraint(:username)
    |> unique_constraint(:email_hash)
  end

  @doc """
  Changeset for updating a user's DM preference.
  Validates the value is one of: anyone, shared_channels, nobody.
  """
  def dm_preference_changeset(user, attrs) do
    user
    |> cast(attrs, [:dm_preference])
    |> validate_inclusion(:dm_preference, @valid_dm_preferences)
  end

  @doc """
  Timing-safe password verification. Returns false (with a dummy hash check)
  when user is nil to prevent timing attacks.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 3, max: 50)
    |> validate_format(:username, ~r/^[a-z0-9._-]+$/,
      message: "must be lowercase alphanumeric with ., _, - allowed"
    )
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> update_change(:email, &String.downcase/1)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, max: 72, message: "should be at least 8 characters")
    |> maybe_hash_password()
  end

  defp put_email_hash(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> put_change(changeset, :email_hash, email)
    end
  end

  defp maybe_hash_password(changeset) do
    if changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(get_change(changeset, :password)))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
