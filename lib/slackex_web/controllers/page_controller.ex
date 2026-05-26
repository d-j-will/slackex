defmodule SlackexWeb.PageController do
  use SlackexWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/chat")
    else
      conn
      |> assign(:loom, FunWithFlags.enabled?(:loom_redesign))
      |> render(:home)
    end
  end
end
