defmodule SlackexWeb.Plugs.MetricsExporterTest do
  use SlackexWeb.ConnCase, async: true

  test "GET /metrics returns prometheus text format", %{conn: conn} do
    conn = get(conn, "/metrics")
    assert conn.status == 200
    assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
    assert content_type =~ "text/plain"
  end
end
