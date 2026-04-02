defmodule SlackexWeb.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SlackexWeb.Telemetry

  defmodule QueueProviderStub do
    def check_queue(_queue) do
      case Process.get(:queue_provider_mode, :ok) do
        :ok -> %{running: [:job1, :job2]}
        :bad_shape -> %{}
        :raise -> raise "boom"
      end
    end
  end

  defmodule PresenceProviderStub do
    def list(_topic) do
      case Process.get(:presence_provider_mode, :ok) do
        :ok -> %{"u1" => %{}, "u2" => %{}}
        :bad_shape -> []
        :raise -> raise "boom"
      end
    end
  end

  setup do
    previous = Application.get_env(:slackex, Telemetry, [])

    Application.put_env(:slackex, Telemetry,
      queue_provider: QueueProviderStub,
      presence_provider: PresenceProviderStub
    )

    Process.put(:queue_provider_mode, :ok)
    Process.put(:presence_provider_mode, :ok)

    on_exit(fn ->
      Application.put_env(:slackex, Telemetry, previous)
      Process.delete(:queue_provider_mode)
      Process.delete(:presence_provider_mode)
    end)

    :ok
  end

  describe "probe failure handling" do
    test "measure_oban_queue_depth logs sanitized warnings on provider failure" do
      Process.put(:queue_provider_mode, :raise)

      log =
        capture_log(fn ->
          Telemetry.measure_oban_queue_depth()
        end)

      assert log =~ "telemetry_probe_failed probe=queue code=queue_probe_failed queue=default"
      assert log =~ "queue=notifications"
      assert log =~ "queue=embeddings"
      assert log =~ "queue=link_previews"
      refute log =~ "boom"
    end

    test "measure_oban_queue_depth logs sanitized warnings on bad shape" do
      Process.put(:queue_provider_mode, :bad_shape)

      log =
        capture_log(fn ->
          Telemetry.measure_oban_queue_depth()
        end)

      assert log =~ "telemetry_probe_failed probe=queue code=queue_probe_failed queue=default"
      refute log =~ "%{}"
    end

    test "measure_connected_users logs a sanitized warning on provider failure" do
      Process.put(:presence_provider_mode, :raise)

      log =
        capture_log(fn ->
          Telemetry.measure_connected_users()
        end)

      assert log =~ "telemetry_probe_failed probe=presence code=presence_probe_failed"
      refute log =~ "boom"
    end

    test "measure_connected_users logs a sanitized warning on bad shape" do
      Process.put(:presence_provider_mode, :bad_shape)

      log =
        capture_log(fn ->
          Telemetry.measure_connected_users()
        end)

      assert log =~ "telemetry_probe_failed probe=presence code=presence_probe_failed"
      refute log =~ "[]"
    end
  end
end
