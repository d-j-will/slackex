defmodule Slackex.Accounts.UserEncryptionTest do
  use Slackex.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Slackex.Accounts
  alias Slackex.Accounts.User

  describe "encrypted email on registration" do
    test "new user registration stores email encrypted and populates email_hash" do
      attrs = %{
        username: "enctest",
        email: "encrypt@example.com",
        password: "password123"
      }

      assert {:ok, user} = Accounts.register_user(attrs)
      assert user.email == "encrypt@example.com"
      assert user.email_hash != nil

      # Verify raw DB value for email column is not plaintext
      %{rows: [[raw_encrypted_email]]} =
        SQL.query!(Repo, "SELECT encrypted_email FROM users WHERE id = $1", [
          user.id
        ])

      refute raw_encrypted_email == "encrypt@example.com"
      assert is_binary(raw_encrypted_email)
    end

    test "login via get_user_by_email_and_password succeeds with correct credentials" do
      attrs = %{
        username: "logintest",
        email: "login@example.com",
        password: "password123"
      }

      {:ok, registered_user} = Accounts.register_user(attrs)

      found_user = Accounts.get_user_by_email_and_password("login@example.com", "password123")
      assert found_user != nil
      assert found_user.id == registered_user.id
    end

    test "login via get_user_by_email_and_password fails with wrong password" do
      attrs = %{
        username: "loginfail",
        email: "loginfail@example.com",
        password: "password123"
      }

      {:ok, _} = Accounts.register_user(attrs)

      refute Accounts.get_user_by_email_and_password("loginfail@example.com", "wrongpassword")
    end

    test "login via get_user_by_email_and_password fails with unknown email" do
      refute Accounts.get_user_by_email_and_password("nobody@example.com", "password123")
    end
  end

  describe "email_hash uniqueness" do
    test "duplicate email registration is rejected via unique constraint on email_hash" do
      attrs = %{
        username: "unique1",
        email: "duplicate@example.com",
        password: "password123"
      }

      assert {:ok, _} = Accounts.register_user(attrs)

      duplicate_attrs = %{
        username: "unique2",
        email: "duplicate@example.com",
        password: "password123"
      }

      assert {:error, changeset} = Accounts.register_user(duplicate_attrs)
      assert %{email_hash: _} = errors_on(changeset)
    end
  end

  describe "email_hash population in changeset" do
    test "registration_changeset populates email_hash from email" do
      changeset =
        User.registration_changeset(%User{}, %{
          username: "hashtest",
          email: "hash@example.com",
          password: "password123"
        })

      assert changeset.valid?
      assert get_change(changeset, :email_hash) != nil
    end

    test "registration_changeset does not populate email_hash when email is absent" do
      changeset =
        User.registration_changeset(%User{}, %{
          username: "noemail",
          password: "password123"
        })

      refute changeset.valid?
      assert get_change(changeset, :email_hash) == nil
    end
  end

  describe "Repo.get_by email_hash lookup" do
    test "Repo.get_by(User, email_hash: email) finds the correct user" do
      attrs = %{
        username: "getbytest",
        email: "getby@example.com",
        password: "password123"
      }

      {:ok, registered_user} = Accounts.register_user(attrs)

      # Cloak.Ecto.HMAC dump is called automatically by Ecto on get_by
      found_user = Repo.get_by(User, email_hash: "getby@example.com")
      assert found_user != nil
      assert found_user.id == registered_user.id
    end
  end
end
