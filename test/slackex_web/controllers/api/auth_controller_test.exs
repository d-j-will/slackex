defmodule SlackexWeb.API.AuthControllerTest do
  use SlackexWeb.ConnCase, async: true

  import Slackex.Factory

  alias Slackex.Accounts.Auth

  setup do
    user = insert(:user)
    %{user: user}
  end

  describe "POST /api/auth/login" do
    test "valid credentials return access_token, refresh_token, and user data", %{
      conn: conn,
      user: user
    } do
      conn = post(conn, ~p"/api/auth/login", %{email: user.email, password: "password123"})

      assert %{
               "access_token" => access_token,
               "refresh_token" => refresh_token,
               "user" => serialized_user
             } = json_response(conn, 200)

      assert is_binary(access_token)
      assert is_binary(refresh_token)
      assert serialized_user["username"] == user.username
      assert serialized_user["id"] == to_string(user.id)
    end

    test "wrong password returns 401", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/auth/login", %{email: user.email, password: "wrongpassword"})
      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "non-existent email returns 401", %{conn: conn} do
      conn =
        post(conn, ~p"/api/auth/login", %{email: "nobody@example.com", password: "password123"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "missing params returns 400 with error message", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/login", %{})

      assert %{"error" => "missing_params", "message" => "email and password are required"} =
               json_response(conn, 400)
    end
  end

  describe "POST /api/auth/refresh" do
    test "valid refresh token returns new access_token and refresh_token", %{
      conn: conn,
      user: user
    } do
      refresh_token = Auth.generate_refresh_token(user)
      conn = post(conn, ~p"/api/auth/refresh", %{refresh_token: refresh_token})

      assert %{"access_token" => access_token, "refresh_token" => new_refresh_token} =
               json_response(conn, 200)

      assert is_binary(access_token)
      assert is_binary(new_refresh_token)
    end

    test "invalid refresh token returns 401", %{conn: conn} do
      conn =
        post(conn, ~p"/api/auth/refresh", %{refresh_token: "garbage.invalid.token"})

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "missing params returns 400 with error message", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/refresh", %{})

      assert %{"error" => "missing_params", "message" => "refresh_token is required"} =
               json_response(conn, 400)
    end
  end
end
