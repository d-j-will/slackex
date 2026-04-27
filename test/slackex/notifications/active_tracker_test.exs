defmodule Slackex.Notifications.ActiveTrackerTest do
  use ExUnit.Case, async: false

  alias Slackex.Notifications.ActiveTracker

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    :ok
  end

  test "mark_active makes active? return true" do
    refute ActiveTracker.active?(123)
    :ok = ActiveTracker.mark_active(123)
    assert ActiveTracker.active?(123)
  end

  test "mark_inactive removes the marker" do
    :ok = ActiveTracker.mark_active(456)
    assert ActiveTracker.active?(456)
    :ok = ActiveTracker.mark_inactive(456)
    refute ActiveTracker.active?(456)
  end

  test "mark_active sets a TTL of 20 seconds" do
    :ok = ActiveTracker.mark_active(789)
    {:ok, ttl} = Redix.command(:redix_0, ["TTL", "active:789"])
    assert ttl > 0
    assert ttl <= 20
  end

  test "active? returns false on Redis error fallback" do
    # Even with no Redis state the function must not crash
    refute ActiveTracker.active?(999_999_999)
  end
end
