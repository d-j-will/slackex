defmodule Slackex.Ops.SystemSummaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Slackex.Ops.SystemSummary

  defmodule ActiveChannelServerProviderStub do
    def channel_count do
      case Process.get(:channel_server_mode, :ok) do
        :ok -> 7
        :bad_shape -> :error
        :raise -> raise "boom"
      end
    end
  end

  defmodule PresenceProviderStub do
    def list(_topic) do
      case Process.get(:presence_mode, :ok) do
        :ok -> %{"u1" => %{}, "u2" => %{}}
        :bad_shape -> []
        :raise -> raise "boom"
      end
    end
  end

  defmodule QueueProviderStub do
    def check_queue(queue) do
      case Process.get(:queue_mode, :ok) do
        :ok -> %{running: [queue]}
        :bad_shape -> %{}
        :raise -> raise "boom"
      end
    end
  end

  setup do
    previous = Application.get_env(:slackex, SystemSummary, [])

    Application.put_env(:slackex, SystemSummary,
      active_channel_server_provider: ActiveChannelServerProviderStub,
      presence_provider: PresenceProviderStub,
      queue_provider: QueueProviderStub
    )

    Process.put(:channel_server_mode, :ok)
    Process.put(:presence_mode, :ok)
    Process.put(:queue_mode, :ok)

    on_exit(fn ->
      Application.put_env(:slackex, SystemSummary, previous)
      Process.delete(:channel_server_mode)
      Process.delete(:presence_mode)
      Process.delete(:queue_mode)
    end)

    :ok
  end

  test "snapshot returns the exact success shape" do
    snapshot = SystemSummary.snapshot()

    assert %{
             "generated_at" => generated_at,
             "node" => node_name,
             "active_channel_servers" => 7,
             "lobby_presence_count" => 2,
             "queue_running_counts" => %{
               "default" => 1,
               "notifications" => 1,
               "embeddings" => 1,
               "link_previews" => 1
             },
             "partial_failures" => %{
               "active_channel_servers" => nil,
               "presence" => nil,
               "queues" => nil
             }
           } = snapshot

    assert {:ok, _, _} = DateTime.from_iso8601(generated_at)
    assert is_binary(node_name)
  end

  test "snapshot falls back on active channel server probe failure with exact shape" do
    Process.put(:channel_server_mode, :raise)

    log =
      capture_log(fn ->
        snapshot = SystemSummary.snapshot()

        assert snapshot["active_channel_servers"] == 0

        assert snapshot["partial_failures"]["active_channel_servers"] ==
                 "channel_server_probe_failed"

        assert snapshot["partial_failures"]["presence"] == nil
        assert snapshot["partial_failures"]["queues"] == nil
      end)

    assert log =~
             "ops_snapshot_probe_failed probe=active_channel_servers code=channel_server_probe_failed"

    refute log =~ "boom"
  end

  test "snapshot falls back on presence probe failure with exact shape" do
    Process.put(:presence_mode, :bad_shape)

    log =
      capture_log(fn ->
        snapshot = SystemSummary.snapshot()

        assert snapshot["lobby_presence_count"] == 0
        assert snapshot["partial_failures"]["active_channel_servers"] == nil
        assert snapshot["partial_failures"]["presence"] == "presence_probe_failed"
        assert snapshot["partial_failures"]["queues"] == nil
      end)

    assert log =~ "ops_snapshot_probe_failed probe=presence code=presence_probe_failed"
    refute log =~ "[]"
  end

  test "snapshot falls back on queue probe failure with exact shape" do
    Process.put(:queue_mode, :raise)

    log =
      capture_log(fn ->
        snapshot = SystemSummary.snapshot()

        assert snapshot["queue_running_counts"] == %{
                 "default" => 0,
                 "notifications" => 0,
                 "embeddings" => 0,
                 "link_previews" => 0
               }

        assert snapshot["partial_failures"]["active_channel_servers"] == nil
        assert snapshot["partial_failures"]["presence"] == nil
        assert snapshot["partial_failures"]["queues"] == "queue_probe_failed"
      end)

    assert log =~ "ops_snapshot_probe_failed probe=queues code=queue_probe_failed"
    refute log =~ "boom"
  end
end
