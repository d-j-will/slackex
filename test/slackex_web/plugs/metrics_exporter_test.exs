defmodule SlackexWeb.Plugs.MetricsExporterTest do
  use SlackexWeb.ConnCase, async: true

  test "GET /metrics returns prometheus text format", %{conn: conn} do
    conn = get(conn, "/metrics")
    assert conn.status == 200
    assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
    assert content_type =~ "text/plain"
  end

  describe "metric name contract" do
    # These tests verify that the actual metric names exported by
    # TelemetryMetricsPrometheus.Core match what the Grafana dashboard
    # queries expect. Catches naming mismatches at CI time rather than
    # during manual Grafana testing.
    #
    # If a metric name changes (library upgrade, refactor), update both
    # the dashboard JSON and these assertions together.

    setup %{conn: conn} do
      # Trigger VM telemetry events manually — the telemetry_poller
      # hasn't fired yet during tests. This tests the full pipeline:
      # telemetry event → Prometheus Core handler → scrape output.
      :telemetry.execute([:vm, :memory], %{
        total: 100_000,
        processes: 50_000,
        binary: 20_000,
        ets: 10_000,
        atom: 5_000
      })

      :telemetry.execute([:vm, :system_counts], %{process_count: 100, port_count: 10})
      :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 0, cpu: 0, io: 0})
      :telemetry.execute([:slackex, :presence, :connected_users], %{count: 0}, %{})
      :telemetry.execute([:slackex, :oban, :queue_depth], %{running: 2}, %{queue: :default})
      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 100_000_000}, %{conn: conn})

      %{body: get(conn, "/metrics").resp_body}
    end

    test "exports VM memory gauges without unit suffix", %{body: body} do
      assert body =~ "vm_memory_total "
      assert body =~ "vm_memory_processes "
      assert body =~ "vm_memory_binary "
      assert body =~ "vm_memory_ets "
      assert body =~ "vm_memory_atom "
    end

    test "exports VM system count gauges", %{body: body} do
      assert body =~ "vm_system_counts_process_count "
      assert body =~ "vm_system_counts_port_count "
    end

    test "exports VM run queue gauges", %{body: body} do
      assert body =~ "vm_total_run_queue_lengths_total "
      assert body =~ "vm_total_run_queue_lengths_cpu "
      assert body =~ "vm_total_run_queue_lengths_io "
    end

    test "exports Ecto query histograms without unit suffix", %{body: body} do
      assert body =~ "slackex_repo_query_total_time_bucket{"
      assert body =~ "slackex_repo_query_query_time_bucket{"
      assert body =~ "slackex_repo_query_queue_time_bucket{"
    end

    test "exports application metrics", %{body: body} do
      assert body =~ "slackex_presence_connected_users_count "
      assert body =~ "slackex_oban_queue_depth_running "
    end

    test "exports Phoenix endpoint histogram", %{body: body} do
      assert body =~ "phoenix_endpoint_stop_duration_bucket{"
    end
  end
end
