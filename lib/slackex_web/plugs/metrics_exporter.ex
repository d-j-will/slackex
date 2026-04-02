defmodule SlackexWeb.Plugs.MetricsExporter do
  @moduledoc """
  Serves Prometheus metrics at /metrics.

  Placed in the endpoint pipeline before the router so it bypasses
  session, CSRF, and auth middleware — Prometheus scrapers don't
  carry cookies or tokens.

  In production, restricts access to private/Docker network IPs only
  (10.x, 172.16-31.x, 192.168.x, 127.x). In dev/test, all IPs are allowed.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/metrics"} = conn, _opts) do
    if allow_metrics?(conn) do
      metrics = TelemetryMetricsPrometheus.Core.scrape(:slackex_metrics)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, metrics)
      |> halt()
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp allow_metrics?(%{remote_ip: remote_ip}) do
    Application.get_env(:slackex, :env) != :prod or internal_network?(remote_ip)
  end

  # IPv4
  defp internal_network?({10, _, _, _}), do: true
  defp internal_network?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp internal_network?({192, 168, _, _}), do: true
  defp internal_network?({127, _, _, _}), do: true
  # IPv6 loopback (::1)
  defp internal_network?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped IPv6 (::ffff:x.x.x.x) — Bandit listens on IPv6, so all IPs arrive this way
  defp internal_network?({0, 0, 0, 0, 0, 65_535, hi, _lo}) do
    # hi byte encodes first two octets of IPv4: e.g., 127.0 = 0x7F00, 172.18 = 0xAC12
    first_octet = Bitwise.bsr(hi, 8)
    second_octet = Bitwise.band(hi, 0xFF)

    first_octet == 127 or
      first_octet == 10 or
      (first_octet == 172 and second_octet >= 16 and second_octet <= 31) or
      (first_octet == 192 and second_octet == 168)
  end

  defp internal_network?(_), do: false
end
