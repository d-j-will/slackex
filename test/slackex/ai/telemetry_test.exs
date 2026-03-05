defmodule Slackex.AI.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Slackex.AI.Telemetry

  setup do
    Telemetry.attach_handlers()
    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous_level)

      :telemetry.list_handlers([:slackex, :ai])
      |> Enum.each(&:telemetry.detach(&1.id))
    end)

    :ok
  end

  describe "completion events" do
    test "logs completion telemetry" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:slackex, :ai, :completion],
            %{duration: 1_200_000},
            %{model: "gemma-3-4b-it", prompt_tokens: 2450, completion_tokens: 312}
          )
        end)

      assert log =~ "[AI] completion"
      assert log =~ "model=gemma-3-4b-it"
      assert log =~ "prompt=2450"
      assert log =~ "completion=312"
    end
  end

  describe "embedding events" do
    test "logs embedding telemetry" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:slackex, :ai, :embedding],
            %{duration: 400_000},
            %{model: "all-MiniLM-L6-v2", tokens: 156, batch_size: 3}
          )
        end)

      assert log =~ "[AI] embedding"
      assert log =~ "model=all-MiniLM-L6-v2"
      assert log =~ "tokens=156"
      assert log =~ "batch=3"
    end
  end
end
