defmodule SlackexWeb.PageController do
  use SlackexWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/chat")
    else
      render(conn, :home)
    end
  end
end
