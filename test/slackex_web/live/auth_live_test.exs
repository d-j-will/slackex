defmodule SlackexWeb.AuthLiveTest do
  use SlackexWeb.ConnCase

  describe "Registration page" do
    test "renders registration form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create an account"
      assert html =~ "Username"
      assert html =~ "Email"
      assert html =~ "Password"
    end

    test "valid attributes create user and redirect to login", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration-form",
          user: %{
            username: "newuser",
            email: "newuser@example.com",
            password: "password1234"
          }
        )
        |> render_submit()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = result
    end

    test "duplicate username shows error", %{conn: conn} do
      existing = insert(:user, username: "taken")

      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html =
        lv
        |> form("#registration-form",
          user: %{
            username: existing.username,
            email: "unique@example.com",
            password: "password1234"
          }
        )
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "weak password shows validation error on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html =
        lv
        |> form("#registration-form",
          user: %{
            username: "testuser",
            email: "test@example.com",
            password: "short"
          }
        )
        |> render_change()

      assert html =~ "should be at least"
    end
  end

  describe "Login page" do
    test "renders login form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in to Slackex"
      assert html =~ "Email"
      assert html =~ "Password"
    end

    test "links to registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ ~p"/users/register"
      assert html =~ "Register"
    end
  end

  describe "Authentication redirects" do
    test "unauthenticated user accessing /chat is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/chat")
    end

    test "authenticated user accessing /users/log-in is redirected to /chat", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/chat"}}} = live(conn, ~p"/users/log-in")
    end

    test "authenticated user accessing /users/register is redirected to /chat", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/chat"}}} = live(conn, ~p"/users/register")
    end
  end
end
