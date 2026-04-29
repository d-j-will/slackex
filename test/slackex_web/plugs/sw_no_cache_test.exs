defmodule SlackexWeb.Plugs.SwNoCacheTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias SlackexWeb.Plugs.SwNoCache

  defp run(path) do
    conn(:get, path)
    |> SwNoCache.call(SwNoCache.init([]))
    |> Plug.Conn.send_resp(200, "ok")
  end

  describe "service worker and manifest paths" do
    test "/service-worker.js gets Cache-Control: no-cache" do
      conn = run("/service-worker.js")

      assert get_resp_header(conn, "cache-control") == [
               "no-cache, no-store, must-revalidate, max-age=0"
             ]

      assert get_resp_header(conn, "pragma") == ["no-cache"]
      assert get_resp_header(conn, "etag") == []
    end

    test "/manifest.json gets Cache-Control: no-cache" do
      conn = run("/manifest.json")

      assert get_resp_header(conn, "cache-control") == [
               "no-cache, no-store, must-revalidate, max-age=0"
             ]
    end
  end

  @sw_cc "no-cache, no-store, must-revalidate, max-age=0"

  describe "other paths" do
    test "/assets/app.js is not overridden by this plug" do
      conn = run("/assets/app.js")
      refute @sw_cc in get_resp_header(conn, "cache-control")
      assert get_resp_header(conn, "pragma") == []
    end

    test "/chat is not overridden" do
      conn = run("/chat")
      refute @sw_cc in get_resp_header(conn, "cache-control")
    end

    test "/service-worker.js.map is NOT matched (exact path only)" do
      conn = run("/service-worker.js.map")
      refute @sw_cc in get_resp_header(conn, "cache-control")
    end
  end
end
