defmodule SlackexWeb.HealthController do
  use SlackexWeb, :controller

  def index(conn, _params) do
    health = %{
      status: "ok",
      node: node() |> Atom.to_string(),
      cluster_nodes: Node.list() |> Enum.map(&Atom.to_string/1),
      cluster_size: length(Node.list()) + 1
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health))
  end
end
