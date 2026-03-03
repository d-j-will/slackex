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

  def ready(conn, _params) do
    db = check_db()
    redis = check_redis()
    status_code = if db == :ok, do: 200, else: 503

    body = %{
      node: node() |> Atom.to_string(),
      cluster_nodes: Node.list() |> Enum.map(&Atom.to_string/1),
      cluster_size: length(Node.list()) + 1,
      channel_count: Slackex.Messaging.channel_count(),
      database: if(db == :ok, do: "ok", else: "error"),
      redis: if(redis == :ok, do: "ok", else: "degraded")
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(body))
  end

  defp check_db do
    case Slackex.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp check_redis do
    Slackex.Cache.Redis.ping()
  end
end
