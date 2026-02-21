defmodule Slackex.AccountsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Accounts
  alias Slackex.Accounts.{Auth, Guardian}
  alias Slackex.Repo

  describe "user registration" do
    test "valid attributes create a user" do
      attrs = %{
        username: "alice",
        email: "alice@example.com",
        password: "password123"
      }

      assert {:ok, user} = Accounts.register_user(attrs)
      assert user.username == "alice"
      assert user.email == "alice@example.com"
      assert user.hashed_password != "password123"
      assert is_nil(user.password)
    end

    test "duplicate username is rejected" do
      insert(:user, username: "bob")

      assert {:error, changeset} =
               Accounts.register_user(%{
                 username: "bob",
                 email: "bob2@example.com",
                 password: "password123"
               })

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "weak password is rejected" do
      assert {:error, changeset} =
               Accounts.register_user(%{
                 username: "carol",
                 email: "carol@example.com",
                 password: "short"
               })

      assert %{password: [_]} = errors_on(changeset)
    end

    test "username must be lowercase alphanumeric" do
      assert {:error, changeset} =
               Accounts.register_user(%{
                 username: "Invalid User!",
                 email: "invalid@example.com",
                 password: "password123"
               })

      assert %{username: [_]} = errors_on(changeset)
    end

    test "username with valid special characters is accepted" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 username: "valid.user_name-1",
                 email: "valid@example.com",
                 password: "password123"
               })

      assert user.username == "valid.user_name-1"
    end
  end

  describe "authentication" do
    test "valid credentials return the user" do
      user =
        insert(:user,
          email: "auth@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("goodpassword")
        )

      result = Accounts.get_user_by_email_and_password("auth@example.com", "goodpassword")
      assert result.id == user.id
    end

    test "wrong password returns nil" do
      insert(:user,
        email: "auth2@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("correctpass")
      )

      result = Accounts.get_user_by_email_and_password("auth2@example.com", "wrongpass")
      assert is_nil(result)
    end

    test "session token can be generated and verified" do
      user = insert(:user)
      token = Accounts.generate_user_session_token(user)
      assert is_binary(token)

      found = Accounts.get_user_by_session_token(token)
      assert found.id == user.id
    end

    test "deleted session token no longer works" do
      user = insert(:user)
      token = Accounts.generate_user_session_token(user)

      Accounts.delete_user_session_token(token)

      result = Accounts.get_user_by_session_token(token)
      assert is_nil(result)
    end
  end

  describe "JWT token lifecycle" do
    test "access token is valid within TTL" do
      user = insert(:user)
      token = Auth.generate_api_token(user)

      assert {:ok, user_id} = Auth.verify_api_token(token)
      assert user_id == user.id
    end

    test "revoked access token (JTI deleted) is rejected" do
      user = insert(:user)
      token = Auth.generate_api_token(user)

      # Verify it works first
      assert {:ok, _} = Auth.verify_api_token(token)

      # Revoke it
      Auth.revoke_token(token)

      assert {:error, _} = Auth.verify_api_token(token)
    end

    test "refresh token exchanges for new access + refresh token pair" do
      user = insert(:user)
      refresh_token = Auth.generate_refresh_token(user)

      assert {:ok, %{access_token: new_access, refresh_token: new_refresh}} =
               Auth.refresh_api_token(refresh_token)

      assert is_binary(new_access)
      assert is_binary(new_refresh)
      assert new_refresh != refresh_token
      assert {:ok, _} = Auth.verify_api_token(new_access)
    end

    test "old refresh token replay within 10-second grace window returns error without family invalidation" do
      user = insert(:user)
      refresh_token = Auth.generate_refresh_token(user)

      # First rotation succeeds
      assert {:ok, %{access_token: _new_access, refresh_token: _new_refresh}} =
               Auth.refresh_api_token(refresh_token)

      # Replay within grace window — should get :token_recently_rotated, NOT family invalidation
      assert {:error, :token_recently_rotated} = Auth.refresh_api_token(refresh_token)

      # User's tokens should still be intact (no family invalidation)
      new_refresh2 = Auth.generate_refresh_token(user)
      assert {:ok, _} = Auth.refresh_api_token(new_refresh2)
    end

    test "replaying a revoked refresh token after grace window invalidates all tokens" do
      user = insert(:user)
      refresh_token = Auth.generate_refresh_token(user)

      # Rotate once
      assert {:ok, _} = Auth.refresh_api_token(refresh_token)

      # Simulate grace window expiry by backdating revoked_at
      alias Slackex.Accounts.UserToken
      import Ecto.Query

      {:ok, claims} = Guardian.decode_and_verify(refresh_token)
      jti = claims["jti"]
      hashed_jti = :crypto.hash(:sha256, jti)
      past = DateTime.add(DateTime.utc_now(), -30, :second)

      Repo.update_all(
        from(t in UserToken,
          where: t.token == ^hashed_jti and t.context == "api_refresh"
        ),
        set: [revoked_at: past]
      )

      # Now replaying should trigger family invalidation
      assert {:error, :token_family_invalidated} = Auth.refresh_api_token(refresh_token)

      # All tokens for user should be deleted
      remaining =
        Repo.all(
          from t in UserToken,
            where: t.user_id == ^user.id and t.context in ["api_access", "api_refresh"]
        )

      assert remaining == []
    end

    test "invalid/malformed JWT is rejected" do
      assert {:error, _} = Auth.verify_api_token("not.a.valid.jwt")
    end
  end
end
