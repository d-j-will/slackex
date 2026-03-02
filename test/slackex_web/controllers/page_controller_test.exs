defmodule SlackexWeb.PageControllerTest do
  use SlackexWeb.ConnCase

  test "GET / renders landing page for unauthenticated users", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Team communication"
    assert html_response(conn, 200) =~ "Get started free"
  end

  test "GET / redirects authenticated users to /chat", %{conn: conn} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/chat"
  end
end
