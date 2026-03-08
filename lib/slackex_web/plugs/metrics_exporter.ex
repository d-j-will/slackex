defmodule SlackexWeb.Plugs.MetricsExporter do
  @moduledoc """
  Serves Prometheus metrics at /metrics.

  Placed in the endpoint pipeline before the router so it bypasses
  session, CSRF, and auth middleware — Prometheus scrapers don't
  carry cookies or tokens.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/metrics"} = conn, _opts) do
    metrics = TelemetryMetricsPrometheus.Core.scrape(:slackex_metrics)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
    |> halt()
  end

  def call(conn, _opts), do: conn
end
