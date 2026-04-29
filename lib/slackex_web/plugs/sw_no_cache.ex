defmodule SlackexWeb.Plugs.SwNoCache do
  @moduledoc """
  Forces `Cache-Control: no-cache, no-store, must-revalidate` on the service
  worker and PWA manifest. Without this, Cloudflare's default 4-hour edge
  cache for `text/javascript` and `application/manifest+json` would pin
  stale copies for hours after every deploy — defeating SW updates and
  manifest changes.

  Wired before `Plug.Static` in `SlackexWeb.Endpoint` and overrides whatever
  cache headers `Plug.Static` would otherwise emit by registering a
  `before_send` hook.
  """

  import Plug.Conn

  @paths ~w(/service-worker.js /manifest.json)

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @paths do
    register_before_send(conn, fn conn ->
      conn
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate, max-age=0")
      |> put_resp_header("pragma", "no-cache")
      |> delete_resp_header("etag")
    end)
  end

  def call(conn, _opts), do: conn
end
