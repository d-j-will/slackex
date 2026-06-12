defmodule SlackexWeb.Plugs.AnalyticsPlug do
  @moduledoc "Tracks HTTP page views and manages analytics session IDs."

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if FunWithFlags.enabled?(:website_analytics) do
      try do
        # This plug runs in the endpoint, before the router's browser
        # pipeline — the session is configured (Plug.Session) but not yet
        # fetched. fetch_session/1 is idempotent, so the router fetching
        # again later is safe.
        conn
        |> fetch_session()
        |> ensure_session_id()
        |> register_page_view_callback()
      rescue
        e ->
          Logger.warning("AnalyticsPlug: crashed, skipping: #{inspect(e)}")
          conn
      end
    else
      conn
    end
  end

  defp ensure_session_id(conn) do
    case get_session(conn, :analytics_session_id) do
      nil ->
        session_id = Ecto.UUID.generate()
        put_session(conn, :analytics_session_id, session_id)

      _existing ->
        conn
    end
  end

  defp register_page_view_callback(conn) do
    register_before_send(conn, fn conn ->
      if conn.status in 200..299 and html_request?(conn) do
        track_page_view(conn)
      end

      conn
    end)
  end

  defp track_page_view(conn) do
    user = conn.assigns[:current_user]
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false

    context = %{
      user_id: if(user, do: user.id),
      session_id: get_session(conn, :analytics_session_id),
      is_bot: is_bot,
      user: user
    }

    case Slackex.Analytics.track(context, "page_view", %{
           path: conn.request_path,
           referrer: get_req_header(conn, "referer") |> List.first(),
           is_reconnect: false
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("AnalyticsPlug: failed to track page_view: #{inspect(reason)}")
    end
  end

  defp html_request?(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _] -> String.contains?(content_type, "text/html")
      [] -> false
    end
  end
end
