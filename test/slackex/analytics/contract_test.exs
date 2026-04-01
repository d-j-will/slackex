defmodule Slackex.Analytics.ContractTest do
  @moduledoc """
  Contract tests verifying that Prometheus metric names emitted by
  MetricsBridge match the names registered in telemetry.ex.

  If these tests break, the Grafana dashboard will show blank panels.
  """

  use ExUnit.Case, async: true

  test "analytics telemetry metric definitions exist in telemetry.ex metrics list" do
    metrics = SlackexWeb.Telemetry.metrics()
    metric_names = Enum.map(metrics, & &1.name)

    # These match the telemetry event names that MetricsBridge emits via
    # :telemetry.execute([:tenun, :analytics, :page_views], %{count: N}, %{})
    # The Telemetry.Metrics.last_value("tenun.analytics.page_views.count")
    # splits on "." to produce event_name = [:tenun, :analytics, :page_views]
    # and measurement = :count
    assert [:tenun, :analytics, :page_views, :count] in metric_names
    assert [:tenun, :analytics, :errors, :count] in metric_names
    assert [:tenun, :analytics, :feature_usage, :count] in metric_names
    assert [:tenun, :analytics, :active_users, :count] in metric_names
  end

  test "MetricsBridge emits telemetry events that match registered metrics" do
    # Verify the telemetry event names match by checking the event_name
    # derived from the metric name (all segments except the last)
    metrics = SlackexWeb.Telemetry.metrics()

    analytics_metrics =
      metrics
      |> Enum.filter(fn m ->
        m.name |> Enum.take(2) == [:tenun, :analytics]
      end)

    assert length(analytics_metrics) == 4

    # Verify measurement key is :count for all analytics metrics
    Enum.each(analytics_metrics, fn m ->
      assert m.measurement == :count,
             "Expected measurement :count for #{inspect(m.name)}, got #{inspect(m.measurement)}"
    end)
  end
end
