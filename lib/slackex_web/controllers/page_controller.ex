defmodule SlackexWeb.PageController do
  use SlackexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
