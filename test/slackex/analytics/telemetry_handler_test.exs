defmodule Slackex.Analytics.TelemetryHandlerTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.TelemetryHandler

  setup do
    FunWithFlags.enable(:website_analytics)
    TelemetryHandler.attach()

    on_exit(fn ->
      :telemetry.detach("analytics-lv-exception")
      :telemetry.detach("analytics-oban-exception")
    end)

    :ok
  end

  describe "LiveView exception handler" do
    test "tracks server_error on LiveView handle_event exception" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        :telemetry.execute(
          [:phoenix, :live_view, :handle_event, :exception],
          %{duration: 1_000_000},
          %{
            event: "click",
            socket: %{assigns: %{current_user: nil}},
            kind: :error,
            reason: %RuntimeError{message: "test error"},
            stacktrace: []
          }
        )

        assert_enqueued(
          worker: Slackex.Analytics.TrackWorker,
          args: %{"event_type" => "server_error"}
        )
      end)
    end
  end

  describe "Oban exception handler" do
    test "tracks oban_error on job exception" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        :telemetry.execute(
          [:oban, :job, :exception],
          %{duration: 2_000_000},
          %{
            job: %Oban.Job{
              worker: "Slackex.Workers.CacheWarmer",
              queue: "default",
              args: %{"key" => "value"},
              attempt: 1
            },
            kind: :error,
            reason: %RuntimeError{message: "job failed"},
            stacktrace: []
          }
        )

        assert_enqueued(
          worker: Slackex.Analytics.TrackWorker,
          args: %{"event_type" => "oban_error"}
        )
      end)
    end
  end
end
